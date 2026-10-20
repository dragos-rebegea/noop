import Foundation

/// The meal a log belongs to, derived from the local time it was logged (never stored).
public enum MealSlot: String, CaseIterable, Sendable {
    case breakfast, lunch, dinner, snack

    /// 5..<11 breakfast, 11..<16 lunch, 16..<22 dinner, otherwise snack.
    public static func slot(forHour hour: Int) -> MealSlot {
        switch hour {
        case 5..<11: return .breakfast
        case 11..<16: return .lunch
        case 16..<22: return .dinner
        default: return .snack
        }
    }

    public static func slot(for date: Date, calendar: Calendar = .current) -> MealSlot {
        slot(forHour: calendar.component(.hour, from: date))
    }
}

/// Portion stepper math: steps that grow with the amount, so small foods move in fine steps and
/// big plates do not need dozens of taps.
public enum PortionStep {
    public static let minimum: Double = 5

    /// The next amount up or down: 5 g steps below 50 g, 10 g below 200 g, 25 g from 200 g.
    /// An amount off the step grid (an estimate of 137 g) snaps to the next grid value in that
    /// direction. Going down uses the step of the band below, so up and down retrace each other.
    /// Never returns less than 5 g.
    public static func next(_ grams: Double, up: Bool) -> Double {
        let g = grams.isFinite ? grams : minimum
        let eps = 1e-9
        if up {
            let step = stepSize(g)
            return max(minimum, ((g + eps) / step).rounded(.down) * step + step)
        }
        let step = stepSize(g - eps)
        return max(minimum, ((g - eps) / step).rounded(.up) * step - step)
    }

    /// `grams` times `factor`, rounded to the nearest 5 g, never below 5 g.
    public static func scaled(_ grams: Double, by factor: Double) -> Double {
        let v = grams * factor
        guard v.isFinite else { return minimum }
        return max(minimum, (v / 5).rounded() * 5)
    }

    private static func stepSize(_ grams: Double) -> Double {
        if grams < 50 { return 5 }
        if grams < 200 { return 10 }
        return 25
    }
}

/// Ranks past logs for one-tap re-log chips: foods usually eaten around this time of day first.
public enum TimeOfDaySuggestions {
    /// Indices into `entries`, one per distinct food (lowercased name + productId, the key
    /// `recentFoods` uses), pointing at that food's most recent entry. Ordered by how many logs of
    /// the food fall within 2 hours of `now`'s hour on any day, then by overall count, then by
    /// recency. At most `limit` indices.
    public static func rank(_ entries: [(name: String, productId: String?, loggedAt: Date)],
                            now: Date, calendar: Calendar, limit: Int) -> [Int] {
        guard limit > 0 else { return [] }
        let nowHour = calendar.component(.hour, from: now)
        struct Tally { var near = 0; var total = 0; var latest: Int; var latestAt: Date }
        var tallies: [String: Tally] = [:]
        for (i, e) in entries.enumerated() {
            let key = e.name.lowercased() + "|" + (e.productId ?? "")
            var t = tallies[key] ?? Tally(latest: i, latestAt: e.loggedAt)
            t.total += 1
            let diff = abs(calendar.component(.hour, from: e.loggedAt) - nowHour)
            if min(diff, 24 - diff) <= 2 { t.near += 1 }
            if e.loggedAt > t.latestAt { t.latest = i; t.latestAt = e.loggedAt }
            tallies[key] = t
        }
        return tallies.values.sorted { a, b in
            if a.near != b.near { return a.near > b.near }
            if a.total != b.total { return a.total > b.total }
            if a.latestAt != b.latestAt { return a.latestAt > b.latestAt }
            return a.latest < b.latest
        }.prefix(limit).map(\.latest)
    }
}
