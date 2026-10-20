import Foundation

/// Why a per-100 g value set looks wrong. Flagged values need explicit confirmation before saving.
public enum PlausibilityIssue: Equatable, Sendable {
    case negativeValue
    case macroMassOver100
    case energyMismatch(expectedKcal: Double)
}

/// Sanity checks for per-100 g values from a photo estimate, a label read or a product database.
public enum Plausibility {
    public static func issues(_ v: MacroPer100g) -> [PlausibilityIssue] {
        var out: [PlausibilityIssue] = []
        if v.kcal < 0 || v.protein < 0 || v.carbs < 0 || v.fat < 0 { out.append(.negativeValue) }
        if v.protein + v.carbs + v.fat > 100 { out.append(.macroMassOver100) }
        let expected = 4 * v.protein + 4 * v.carbs + 9 * v.fat
        if abs(v.kcal - expected) > max(40, 0.25 * v.kcal) {
            out.append(.energyMismatch(expectedKcal: expected))
        }
        return out
    }
}
