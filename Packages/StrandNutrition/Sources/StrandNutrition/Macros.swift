import Foundation

/// Absolute energy and macronutrients for an eaten amount (kcal and grams).
public struct Macros: Equatable, Codable, Sendable {
    public var kcal: Double
    public var protein: Double
    public var carbs: Double
    public var fat: Double

    public init(kcal: Double, protein: Double, carbs: Double, fat: Double) {
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
    }

    public static let zero = Macros(kcal: 0, protein: 0, carbs: 0, fat: 0)

    public static func + (l: Macros, r: Macros) -> Macros {
        Macros(kcal: l.kcal + r.kcal, protein: l.protein + r.protein,
               carbs: l.carbs + r.carbs, fat: l.fat + r.fat)
    }
}

/// Energy and macronutrients per 100 g of a food, the unit product databases and labels use.
public struct MacroPer100g: Equatable, Codable, Sendable {
    public var kcal: Double
    public var protein: Double
    public var carbs: Double
    public var fat: Double

    public init(kcal: Double, protein: Double, carbs: Double, fat: Double) {
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
    }

    /// Macros for `grams` of this food.
    public func scaled(grams: Double) -> Macros {
        let f = grams / 100
        return Macros(kcal: kcal * f, protein: protein * f, carbs: carbs * f, fat: fat * f)
    }
}

extension Sequence where Element == Macros {
    /// Component-wise total; `.zero` for an empty sequence.
    public func sum() -> Macros { reduce(.zero, +) }
}
