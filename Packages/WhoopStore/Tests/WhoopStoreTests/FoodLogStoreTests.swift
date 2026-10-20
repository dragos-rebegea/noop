import XCTest
import GRDB
@testable import WhoopStore

final class FoodLogStoreTests: XCTestCase {
    func testV48CreatesFoodTables() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        let entryColumns = try await store.columnNamesForTest(table: "foodEntry")
        let productColumns = try await store.columnNamesForTest(table: "foodProduct")
        XCTAssertTrue(tables.contains("foodEntry"))
        XCTAssertTrue(tables.contains("foodProduct"))
        XCTAssertEqual(entryColumns,
                       ["id", "deviceId", "day", "loggedAt", "name", "grams", "kcal", "proteinG",
                        "carbsG", "fatG", "source", "productId"])
        XCTAssertEqual(productColumns,
                       ["id", "deviceId", "name", "brand", "kcal100", "protein100", "carbs100", "fat100",
                        "servingGrams", "origin", "updatedAt"])
        XCTAssertTrue(DeviceRegistryStore.deviceScopedTables.contains("foodEntry"))
        XCTAssertTrue(DeviceRegistryStore.deviceScopedTables.contains("foodProduct"))
    }

    private func entry(_ id: String, day: String = "2026-10-20", at: Int = 1_000, name: String = "Oats",
                       kcal: Double = 200, p: Double = 10, c: Double = 30, f: Double = 4,
                       productId: String? = nil, grams: Double? = 50) -> FoodEntryRow {
        FoodEntryRow(id: id, deviceId: FoodLog.deviceId, day: day, loggedAt: at, name: name, grams: grams,
                     kcal: kcal, proteinG: p, carbsG: c, fatG: f, source: "quick", productId: productId)
    }

    private func totals(_ store: WhoopStore, _ day: String) async throws -> [String: Double] {
        var out: [String: Double] = [:]
        for k in FoodLog.metricKeys {
            out[k] = try await store.metricSeries(deviceId: FoodLog.deviceId, key: k, from: day, to: day).first?.value
        }
        return out
    }

    func testInsertRecomputesDayTotals() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insertFoodEntries([entry("a"), entry("b", kcal: 100, p: 5, c: 10, f: 1)])
        let t = try await totals(store, "2026-10-20")
        let ids = try await store.foodEntries(deviceId: FoodLog.deviceId, day: "2026-10-20").map(\.id)
        XCTAssertEqual(t["calories_in"], 300)
        XCTAssertEqual(t["protein_g"], 15)
        XCTAssertEqual(t["carbs_g"], 40)
        XCTAssertEqual(t["fat_g"], 5)
        XCTAssertEqual(ids, ["a", "b"])
    }

    func testUpdateAndDeleteKeepTotalsRight() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insertFoodEntries([entry("a"), entry("b", kcal: 100)])
        var a = entry("a"); a.kcal = 50
        try await store.updateFoodEntry(a)
        let updatedCalories = try await totals(store, "2026-10-20")["calories_in"]
        let deleted = try await store.deleteFoodEntry(id: "b")
        let remainingCalories = try await totals(store, "2026-10-20")["calories_in"]
        XCTAssertEqual(updatedCalories, 150)
        XCTAssertTrue(deleted)
        XCTAssertEqual(remainingCalories, 50)
    }

    func testDeletingLastEntryRemovesDayRows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insertFoodEntries([entry("a")])
        let deleted = try await store.deleteFoodEntry(id: "a")
        let t = try await totals(store, "2026-10-20")
        let deletedAgain = try await store.deleteFoodEntry(id: "a")
        XCTAssertTrue(deleted)
        XCTAssertTrue(t.values.isEmpty)
        XCTAssertFalse(deletedAgain)
    }

    func testNutritionCsvRowsUntouched() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([MetricPoint(day: "2026-10-20", key: "calories_in", value: 2000)],
                                           deviceId: "nutrition-csv")
        try await store.insertFoodEntries([entry("a")])
        _ = try await store.deleteFoodEntry(id: "a")
        let csv = try await store.metricSeries(deviceId: "nutrition-csv", key: "calories_in",
                                               from: "2026-10-20", to: "2026-10-20")
        XCTAssertEqual(csv.first?.value, 2000)
    }

    func testRecentGroupsByNameAndProductOrderedByCount() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insertFoodEntries([
            entry("1", at: 100, name: "Oats", grams: 40),
            entry("2", at: 200, name: "Banana", grams: 120),
            entry("3", at: 300, name: "Oats", grams: 60),
        ])
        let recent = try await store.recentFoods(deviceId: FoodLog.deviceId, sinceTs: 0, limit: 10)
        XCTAssertEqual(recent.map(\.name), ["Oats", "Banana"])
        XCTAssertEqual(recent.first?.grams, 60)
    }

    func testRejectsNegativeOrNonFinite() async throws {
        let store = try await WhoopStore.inMemory()
        do { try await store.insertFoodEntries([entry("a", kcal: -1)]); XCTFail("expected throw") }
        catch is FoodLog.InvalidEntry {}
        do { try await store.insertFoodEntries([entry("b", p: .nan)]); XCTFail("expected throw") }
        catch is FoodLog.InvalidEntry {}
        let entries = try await store.foodEntries(deviceId: FoodLog.deviceId, day: "2026-10-20")
        XCTAssertTrue(entries.isEmpty)
    }

    func testProductUpsertAndFetch() async throws {
        let store = try await WhoopStore.inMemory()
        let p = FoodProductRow(id: "5941234567890", deviceId: FoodLog.deviceId, name: "Oats", brand: nil,
                               kcal100: 372, protein100: 13.5, carbs100: 58.7, fat100: 7, servingGrams: 40,
                               origin: "off", updatedAt: 1)
        try await store.upsertFoodProduct(p)
        let inserted = try await store.foodProduct(id: "5941234567890")
        XCTAssertEqual(inserted, p)
        var q = p; q.kcal100 = 380; q.updatedAt = 2
        try await store.upsertFoodProduct(q)
        let updated = try await store.foodProduct(id: "5941234567890")
        let missing = try await store.foodProduct(id: "missing")
        XCTAssertEqual(updated?.kcal100, 380)
        XCTAssertNil(missing)
    }

    func testFoodEntriesInRange() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insertFoodEntries([entry("a", day: "2026-10-18"), entry("b", day: "2026-10-20"),
                                           entry("c", day: "2026-10-21")])
        let rows = try await store.foodEntries(deviceId: FoodLog.deviceId, from: "2026-10-18", to: "2026-10-20")
        XCTAssertEqual(rows.map(\.id), ["a", "b"])
    }

    func testDeleteAllDataClearsFood() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insertFoodEntries([entry("a")])
        try await store.upsertFoodProduct(FoodProductRow(id: "1", deviceId: FoodLog.deviceId, name: "x", brand: nil,
            kcal100: 1, protein100: 0, carbs100: 0, fat100: 0, servingGrams: nil, origin: "manual", updatedAt: 1))
        try await store.deleteAllData(deviceId: FoodLog.deviceId)
        let entries = try await store.foodEntries(deviceId: FoodLog.deviceId, day: "2026-10-20")
        let product = try await store.foodProduct(id: "1")
        let totals = try await store.metricSeries(deviceId: FoodLog.deviceId, key: "calories_in",
                                                  from: "2026-10-20", to: "2026-10-20")
        XCTAssertTrue(entries.isEmpty)
        XCTAssertNil(product)
        XCTAssertTrue(totals.isEmpty)
    }
}
