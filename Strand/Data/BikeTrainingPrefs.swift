import Foundation

/// Bike training settings (FTP, target intensity band, fuelling reminders), kept on device in
/// UserDefaults. Read by the live bike layout, the ride summary and the guided FTP test.
enum BikeTrainingPrefs {
    static let ftpKey = "bike.ftpW"
    static let targetIFLowKey = "bike.targetIFLow"
    static let targetIFHighKey = "bike.targetIFHigh"
    static let fuelIntervalKey = "bike.fuelIntervalMin"
    static let carbsPerHourKey = "bike.carbsPerHour"

    static let defaultTargetIFLow = 0.65
    static let defaultTargetIFHigh = 0.72
    static let defaultFuelIntervalMin = 20
    static let defaultCarbsPerHour = 80
    /// Accepted FTP range in watts; anything outside reads as "not set".
    static let ftpRange = 50...600

    /// The rider's FTP in watts, or nil when not set.
    static func ftp(_ defaults: UserDefaults = .standard) -> Int? {
        let v = defaults.integer(forKey: ftpKey)
        return ftpRange.contains(v) ? v : nil
    }

    /// Stores the FTP (nil or an out-of-range value clears it).
    static func setFTP(_ watts: Int?, _ defaults: UserDefaults = .standard) {
        if let watts, ftpRange.contains(watts) {
            defaults.set(watts, forKey: ftpKey)
        } else {
            defaults.removeObject(forKey: ftpKey)
        }
    }

    /// Target intensity factor band (low, high), ordered and clamped to 0.4 ... 1.2.
    static func targetIF(_ defaults: UserDefaults = .standard) -> ClosedRange<Double> {
        let lo = defaults.object(forKey: targetIFLowKey) as? Double ?? defaultTargetIFLow
        let hi = defaults.object(forKey: targetIFHighKey) as? Double ?? defaultTargetIFHigh
        let a = min(max(min(lo, hi), 0.4), 1.2)
        let b = min(max(max(lo, hi), 0.4), 1.2)
        return a...b
    }

    /// Target band in watts for the stored FTP, or nil without FTP.
    static func targetWatts(ftp: Int?, band: ClosedRange<Double>) -> ClosedRange<Double>? {
        guard let ftp else { return nil }
        return (Double(ftp) * band.lowerBound)...(Double(ftp) * band.upperBound)
    }

    /// Minutes between fuelling reminders; 0 means off.
    static func fuelIntervalMin(_ defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: fuelIntervalKey) != nil else { return defaultFuelIntervalMin }
        return max(0, min(120, defaults.integer(forKey: fuelIntervalKey)))
    }

    /// Carbohydrate target in grams per hour.
    static func carbsPerHour(_ defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: carbsPerHourKey) != nil else { return defaultCarbsPerHour }
        return max(0, min(200, defaults.integer(forKey: carbsPerHourKey)))
    }

    /// Grams of carbohydrate per reminder: carbs per hour scaled to the interval, rounded.
    static func carbsPerReminder(carbsPerHour: Int, intervalMin: Int) -> Int {
        Int((Double(carbsPerHour) * Double(intervalMin) / 60).rounded())
    }

    /// Number of fuelling reminders due after `elapsedSec` of riding (0 when reminders are off).
    static func fuelRemindersDue(elapsedSec: Int, intervalMin: Int) -> Int {
        guard intervalMin > 0, elapsedSec > 0 else { return 0 }
        return elapsedSec / (intervalMin * 60)
    }

    /// Whether a ride's FTP estimate is worth offering as an update: always when no FTP is set, else
    /// only when it differs from the current one by more than 3 %.
    static func suggestsFTPUpdate(estimate: Int?, current: Int?) -> Bool {
        guard let estimate, ftpRange.contains(estimate) else { return false }
        guard let current, current > 0 else { return true }
        return abs(Double(estimate - current)) / Double(current) > 0.03
    }
}

/// Unit-suffixed figures for the bike screens. Numbers and units only, nothing to translate.
enum BikeFormat {
    static func percent1(_ value: Double) -> String { String(format: "%.1f", value) + "%" }
    static func wattsPerKg(_ value: Double) -> String { String(format: "%.1f", value) + " W/kg" }
    static func watts(_ value: Double) -> String { "\(Int(value.rounded())) W" }
    static func zoneTag(_ zone: Int, _ name: String) -> String { "Z\(zone) \(name)" }
}
