import Foundation
import Combine
import StrandNutrition
import WhoopStore

/// State for the Food screens: today's entries, totals, targets and recent foods.
@MainActor
final class FoodLogModel: ObservableObject {
    static let targetKeys = (kcal: "food.target.kcal", protein: "food.target.proteinG",
                             carbs: "food.target.carbsG", fat: "food.target.fatG")

    /// The day being shown. Recomputed on every load and before every write, so a screen left open
    /// across midnight never files new food under yesterday.
    @Published private(set) var day: String = FoodDay.key(for: Date())
    @Published private(set) var entries: [FoodEntryRow] = []
    @Published private(set) var recent: [FoodEntryRow] = []
    @Published var errorMessage: String?

    var totals: Macros { entries.map(\.macros).sum() }

    var targets: Macros {
        let d = UserDefaults.standard
        return Macros(kcal: d.double(forKey: Self.targetKeys.kcal), protein: d.double(forKey: Self.targetKeys.protein),
                      carbs: d.double(forKey: Self.targetKeys.carbs), fat: d.double(forKey: Self.targetKeys.fat))
    }

    private let repo: Repository
    init(repo: Repository) { self.repo = repo }

    func load() async {
        day = FoodDay.key(for: Date())
        guard let store = await repo.storeHandle() else { return }
        do {
            entries = try await store.foodEntries(deviceId: FoodLog.deviceId, day: day)
            let since = Int(Date().timeIntervalSince1970) - 30 * 86_400
            recent = try await store.recentFoods(deviceId: FoodLog.deviceId, sinceTs: since, limit: 30)
        } catch { errorMessage = error.localizedDescription }
    }

    /// One item to log at `grams` of a per-100 g food.
    struct Pending { var name: String; var grams: Double; var per100g: MacroPer100g; var source: String; var productId: String? }

    /// Logs all items in ONE transaction. Returns false (and sets `errorMessage`) when nothing was
    /// saved, so callers dismiss only on success and a multi-item photo never half-saves.
    @discardableResult
    func log(_ items: [Pending]) async -> Bool {
        let now = Date()
        let rows = items.map { i -> FoodEntryRow in
            let m = i.per100g.scaled(grams: i.grams)
            return FoodEntryRow(id: UUID().uuidString, deviceId: FoodLog.deviceId, day: FoodDay.key(for: now),
                                loggedAt: Int(now.timeIntervalSince1970), name: i.name, grams: i.grams,
                                kcal: m.kcal, proteinG: m.protein, carbsG: m.carbs, fatG: m.fat,
                                source: i.source, productId: i.productId)
        }
        return await insert(rows)
    }

    /// Quick add: totals typed by hand.
    @discardableResult
    func quickAdd(name: String, macros m: Macros) async -> Bool {
        let now = Date()
        return await insert([FoodEntryRow(id: UUID().uuidString, deviceId: FoodLog.deviceId, day: FoodDay.key(for: now),
                                          loggedAt: Int(now.timeIntervalSince1970), name: name, grams: nil,
                                          kcal: m.kcal, proteinG: m.protein, carbsG: m.carbs, fatG: m.fat,
                                          source: "quick", productId: nil)])
    }

    /// Re-logs a recent entry, optionally at a new amount (scales its macros linearly).
    @discardableResult
    func relog(_ r: FoodEntryRow, grams: Double? = nil) async -> Bool {
        var m = r.macros
        if let g = grams, let old = r.grams, old > 0 {
            let f = g / old
            m = Macros(kcal: m.kcal * f, protein: m.protein * f, carbs: m.carbs * f, fat: m.fat * f)
        }
        let now = Date()
        return await insert([FoodEntryRow(id: UUID().uuidString, deviceId: FoodLog.deviceId, day: FoodDay.key(for: now),
                                          loggedAt: Int(now.timeIntervalSince1970), name: r.name, grams: grams ?? r.grams,
                                          kcal: m.kcal, proteinG: m.protein, carbsG: m.carbs, fatG: m.fat,
                                          source: "recent", productId: r.productId)])
    }

    func delete(_ r: FoodEntryRow) async {
        guard let store = await repo.storeHandle() else { return }
        do { _ = try await store.deleteFoodEntry(id: r.id) } catch { errorMessage = error.localizedDescription }
        await load()
    }

    func store() async -> WhoopStore? { await repo.storeHandle() }

    private func insert(_ rows: [FoodEntryRow]) async -> Bool {
        guard rows.allSatisfy({ FoodLog.isValid($0.macros) && ($0.grams ?? 1) > 0 }) else {
            errorMessage = String(localized: "Values must be zero or more.")
            return false
        }
        guard let store = await repo.storeHandle() else { return false }
        do {
            try await store.insertFoodEntries(rows)
            errorMessage = nil
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
