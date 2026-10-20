import Foundation
import StrandNutrition
import WhoopStore

/// Barcode to product: local cache first, then (only when the user enabled it) Open Food Facts.
/// Only the barcode number leaves the device. Disclosed in PRIVACY_SECURITY.md section 1.1.
enum FoodProductLookup {
    /// Settings toggle, default off.
    static let offEnabledKey = "food.offLookupEnabled"
    static var offEnabled: Bool { UserDefaults.standard.bool(forKey: offEnabledKey) }

    enum Outcome: Equatable {
        case product(FoodProductRow)       // usable: cached or freshly fetched with all macros
        case incomplete(name: String)      // found on OFF but missing macros
        case notFound
        case lookupDisabled
    }

    struct LookupFailed: Error { let status: Int }

    static func lookup(barcode: String, store: WhoopStore, session: URLSession = .shared) async throws -> Outcome {
        if let cached = try await store.foodProduct(id: barcode) { return .product(cached) }
        guard offEnabled else { return .lookupDisabled }
        var comps = URLComponents(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json")!
        comps.queryItems = [URLQueryItem(name: "fields", value: OpenFoodFacts.fields)]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 15
        req.setValue("NOOP-iOS/1.0 (personal macro logger)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return .notFound }
        guard (200..<300).contains(status) else { throw LookupFailed(status: status) }
        switch try OpenFoodFacts.decode(data) {
        case .notFound:
            return .notFound
        case .found(let p):
            guard let m = p.per100g else { return .incomplete(name: p.name) }
            let row = FoodProductRow(id: barcode, deviceId: FoodLog.deviceId, name: p.name, brand: p.brand,
                                     kcal100: m.kcal, protein100: m.protein, carbs100: m.carbs, fat100: m.fat,
                                     servingGrams: p.servingGrams, origin: "off",
                                     updatedAt: Int(Date().timeIntervalSince1970))
            try await store.upsertFoodProduct(row)
            return .product(row)
        }
    }
}
