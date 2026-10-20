import Foundation
import GRDB
import StrandNutrition

/// Constants for the macro logger's storage.
public enum FoodLog {
    /// Fixed owner for food rows and their metricSeries totals, like the journal's "noop-journal":
    /// food is not tied to whichever strap is active.
    public static let deviceId = "noop-food"
    /// The existing nutrition metric keys (NutritionCsvImport), so Compare/Explore pick totals up.
    public static let metricKeys = ["calories_in", "protein_g", "carbs_g", "fat_g"]

    /// Finite and non-negative in every component. The store rejects anything else.
    public static func isValid(_ m: Macros) -> Bool {
        [m.kcal, m.protein, m.carbs, m.fat].allSatisfy { $0.isFinite && $0 >= 0 }
    }

    public struct InvalidEntry: Error {}
}

public struct FoodEntryRow: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var deviceId: String
    public var day: String
    public var loggedAt: Int
    public var name: String
    public var grams: Double?
    public var kcal: Double
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double
    public var source: String
    public var productId: String?

    public init(id: String, deviceId: String, day: String, loggedAt: Int, name: String, grams: Double?,
                kcal: Double, proteinG: Double, carbsG: Double, fatG: Double, source: String, productId: String?) {
        self.id = id; self.deviceId = deviceId; self.day = day; self.loggedAt = loggedAt; self.name = name
        self.grams = grams; self.kcal = kcal; self.proteinG = proteinG; self.carbsG = carbsG; self.fatG = fatG
        self.source = source; self.productId = productId
    }

    public var macros: Macros { Macros(kcal: kcal, protein: proteinG, carbs: carbsG, fat: fatG) }

    static func decode(_ row: Row) -> FoodEntryRow {
        FoodEntryRow(id: row["id"], deviceId: row["deviceId"], day: row["day"], loggedAt: row["loggedAt"],
                     name: row["name"], grams: row["grams"], kcal: row["kcal"], proteinG: row["proteinG"],
                     carbsG: row["carbsG"], fatG: row["fatG"], source: row["source"], productId: row["productId"])
    }
}

public struct FoodProductRow: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var deviceId: String
    public var name: String
    public var brand: String?
    public var kcal100: Double
    public var protein100: Double
    public var carbs100: Double
    public var fat100: Double
    public var servingGrams: Double?
    public var origin: String
    public var updatedAt: Int

    public init(id: String, deviceId: String, name: String, brand: String?, kcal100: Double, protein100: Double,
                carbs100: Double, fat100: Double, servingGrams: Double?, origin: String, updatedAt: Int) {
        self.id = id; self.deviceId = deviceId; self.name = name; self.brand = brand; self.kcal100 = kcal100
        self.protein100 = protein100; self.carbs100 = carbs100; self.fat100 = fat100
        self.servingGrams = servingGrams; self.origin = origin; self.updatedAt = updatedAt
    }

    public var per100g: MacroPer100g {
        MacroPer100g(kcal: kcal100, protein: protein100, carbs: carbs100, fat: fat100)
    }

    static func decode(_ row: Row) -> FoodProductRow {
        FoodProductRow(id: row["id"], deviceId: row["deviceId"], name: row["name"], brand: row["brand"],
                       kcal100: row["kcal100"], protein100: row["protein100"], carbs100: row["carbs100"],
                       fat100: row["fat100"], servingGrams: row["servingGrams"], origin: row["origin"],
                       updatedAt: row["updatedAt"])
    }
}

extension WhoopStore {
    /// Inserts entries and recomputes the totals of every day they touch, in one transaction.
    public func insertFoodEntries(_ rows: [FoodEntryRow]) async throws {
        guard !rows.isEmpty else { return }
        guard rows.allSatisfy({ FoodLog.isValid($0.macros) }) else { throw FoodLog.InvalidEntry() }
        try syncWrite { db in
            for r in rows { try Self.writeFoodEntry(r, in: db) }
            for ref in Set(rows.map { FoodDayRef(deviceId: $0.deviceId, day: $0.day) }) {
                try Self.recomputeFoodDay(deviceId: ref.deviceId, day: ref.day, in: db)
            }
        }
    }

    /// Replaces an existing entry; recomputes both its old and new day.
    public func updateFoodEntry(_ r: FoodEntryRow) async throws {
        guard FoodLog.isValid(r.macros) else { throw FoodLog.InvalidEntry() }
        try syncWrite { db in
            let oldDay = try String.fetchOne(db, sql: "SELECT day FROM foodEntry WHERE id = ?", arguments: [r.id])
            try Self.writeFoodEntry(r, in: db)
            try Self.recomputeFoodDay(deviceId: r.deviceId, day: r.day, in: db)
            if let oldDay, oldDay != r.day {
                try Self.recomputeFoodDay(deviceId: r.deviceId, day: oldDay, in: db)
            }
        }
    }

    /// Deletes one entry; returns false when it did not exist.
    @discardableResult
    public func deleteFoodEntry(id: String) async throws -> Bool {
        try syncWrite { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT deviceId, day FROM foodEntry WHERE id = ?",
                                             arguments: [id]) else { return false }
            try db.execute(sql: "DELETE FROM foodEntry WHERE id = ?", arguments: [id])
            try Self.recomputeFoodDay(deviceId: row["deviceId"], day: row["day"], in: db)
            return true
        }
    }

    public func foodEntries(deviceId: String, day: String) async throws -> [FoodEntryRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM foodEntry WHERE deviceId = ? AND day = ? ORDER BY loggedAt, id
                """, arguments: [deviceId, day]).map(FoodEntryRow.decode)
        }
    }

    /// Entries for an inclusive `yyyy-MM-dd` day range, oldest first.
    public func foodEntries(deviceId: String, from: String, to: String) async throws -> [FoodEntryRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM foodEntry WHERE deviceId = ? AND day >= ? AND day <= ? ORDER BY day, loggedAt, id
                """, arguments: [deviceId, from, to]).map(FoodEntryRow.decode)
        }
    }

    /// Distinct foods (name + productId) logged since `sinceTs`, most frequent first, then most recent.
    /// Each result is that food's most recent entry, so its grams are the last amount used.
    public func recentFoods(deviceId: String, sinceTs: Int, limit: Int) async throws -> [FoodEntryRow] {
        let rows = try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM foodEntry WHERE deviceId = ? AND loggedAt >= ? ORDER BY loggedAt DESC
                """, arguments: [deviceId, sinceTs]).map(FoodEntryRow.decode)
        }
        var latest: [String: FoodEntryRow] = [:]
        var count: [String: Int] = [:]
        for r in rows {
            let k = r.name.lowercased() + "|" + (r.productId ?? "")
            count[k, default: 0] += 1
            if latest[k] == nil { latest[k] = r }
        }
        return latest.sorted {
            let (ca, cb) = (count[$0.key]!, count[$1.key]!)
            return ca != cb ? ca > cb : $0.value.loggedAt > $1.value.loggedAt
        }.prefix(limit).map(\.value)
    }

    public func upsertFoodProduct(_ p: FoodProductRow) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO foodProduct (id, deviceId, name, brand, kcal100, protein100, carbs100, fat100,
                                         servingGrams, origin, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    deviceId = excluded.deviceId, name = excluded.name, brand = excluded.brand,
                    kcal100 = excluded.kcal100, protein100 = excluded.protein100, carbs100 = excluded.carbs100,
                    fat100 = excluded.fat100, servingGrams = excluded.servingGrams, origin = excluded.origin,
                    updatedAt = excluded.updatedAt
                """, arguments: [p.id, p.deviceId, p.name, p.brand, p.kcal100, p.protein100, p.carbs100,
                                 p.fat100, p.servingGrams, p.origin, p.updatedAt])
        }
    }

    public func foodProduct(id: String) async throws -> FoodProductRow? {
        try syncRead { db in
            try Row.fetchOne(db, sql: "SELECT * FROM foodProduct WHERE id = ?", arguments: [id])
                .map(FoodProductRow.decode)
        }
    }

    private struct FoodDayRef: Hashable { let deviceId: String; let day: String }

    static func writeFoodEntry(_ r: FoodEntryRow, in db: Database) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO foodEntry
                (id, deviceId, day, loggedAt, name, grams, kcal, proteinG, carbsG, fatG, source, productId)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [r.id, r.deviceId, r.day, r.loggedAt, r.name, r.grams, r.kcal, r.proteinG,
                             r.carbsG, r.fatG, r.source, r.productId])
    }

    /// Rewrites the day's four metricSeries totals under `deviceId`, or removes them when the day is empty.
    static func recomputeFoodDay(deviceId: String, day: String, in db: Database) throws {
        let entries = try Row.fetchAll(db, sql: "SELECT * FROM foodEntry WHERE deviceId = ? AND day = ?",
                                       arguments: [deviceId, day]).map(FoodEntryRow.decode)
        if entries.isEmpty {
            for key in FoodLog.metricKeys {
                try db.execute(sql: "DELETE FROM metricSeries WHERE deviceId = ? AND day = ? AND key = ?",
                               arguments: [deviceId, day, key])
            }
            return
        }
        let t = entries.map(\.macros).sum()
        let values = [t.kcal, t.protein, t.carbs, t.fat]
        let points = zip(FoodLog.metricKeys, values).map { MetricPoint(day: day, key: $0.0, value: $0.1) }
        _ = try upsertMetricSeries(points, deviceId: deviceId, in: db)
    }
}
