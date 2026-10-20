import Foundation

/// Progress of an eaten amount toward a daily target, for rings and dot grids.
public enum MacroProgress {
    /// 0...1 fraction of `target` (0 when there is no target).
    public static func fraction(_ value: Double, target: Double) -> Double {
        guard target > 0, value.isFinite, value > 0 else { return 0 }
        return min(value / target, 1)
    }

    /// Filled dots out of `total` (rounded down, so a dot means "earned"; full only at or over target).
    public static func filledDots(_ value: Double, target: Double, total: Int) -> Int {
        guard total > 0 else { return 0 }
        if target > 0, value >= target { return total }
        return Int((fraction(value, target: target) * Double(total)).rounded(.down))
    }

    public static func isOver(_ value: Double, target: Double) -> Bool {
        target > 0 && value > target
    }
}
