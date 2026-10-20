import Foundation

/// Food belongs to the local calendar day it was eaten (not the sleep wake-day convention).
public enum FoodDay {
    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
