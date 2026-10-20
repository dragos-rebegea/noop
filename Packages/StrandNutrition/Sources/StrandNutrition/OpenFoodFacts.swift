import Foundation

/// Decoding for the Open Food Facts product API v2 (`/api/v2/product/<code>.json`).
public enum OpenFoodFacts {
    public struct Product: Equatable, Sendable {
        public var name: String
        public var brand: String?
        public var servingGrams: Double?
        /// nil unless protein, carbs, fat and an energy value are all present.
        public var per100g: MacroPer100g?
    }

    public enum Result: Equatable, Sendable {
        case found(Product)
        case notFound
    }

    public struct DecodeError: Error {}

    /// Fields requested with `?fields=` so the response stays small.
    public static let fields = "product_name,brands,serving_quantity,nutriments"

    public static func decode(_ data: Data) throws -> Result {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError()
        }
        guard number(root["status"]) == 1, let product = root["product"] as? [String: Any] else {
            return .notFound
        }
        let name = (product["product_name"] as? String)?.trimmingCharacters(in: .whitespaces)
        let brand = (product["brands"] as? String)?
            .split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        let n = product["nutriments"] as? [String: Any] ?? [:]
        var per100g: MacroPer100g?
        let kcal = number(n["energy-kcal_100g"]) ?? number(n["energy_100g"]).map { $0 / 4.184 }
        if let kcal, let p = number(n["proteins_100g"]), let c = number(n["carbohydrates_100g"]),
           let f = number(n["fat_100g"]) {
            per100g = MacroPer100g(kcal: kcal, protein: p, carbs: c, fat: f)
        }
        return .found(Product(
            name: (name?.isEmpty == false ? name : nil) ?? "Unnamed product",
            brand: (brand?.isEmpty == false) ? brand : nil,
            servingGrams: number(product["serving_quantity"]).flatMap { $0 > 0 ? $0 : nil },
            per100g: per100g))
    }

    /// OFF mixes numbers and numeric strings for the same field.
    static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
