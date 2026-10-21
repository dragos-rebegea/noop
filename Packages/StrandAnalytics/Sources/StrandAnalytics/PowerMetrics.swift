import Foundation
import WhoopProtocol

// Cycling power metrics from the per-second FTMS companion samples.
//
// PURE. Inputs are `MachineSample` arrays (`t` = wall-clock seconds from the workout start, paused
// seconds carry no sample) and plain heart-rate points; outputs are numbers. The formulas are the
// standard public ones (Coggan Normalized Power / IF / TSS and power zones, Friel aerobic decoupling),
// pinned by hand-computed vectors in PowerMetricsTests.
//
// A missing second is a gap, never zero power. Negative power values are ignored, matching
// `MachineSummary.from`.

/// One heart-rate reading on the machine-sample time axis (seconds from the workout start).
public struct PowerHRPoint: Equatable, Sendable {
    public let t: Int
    public let bpm: Double

    public init(t: Int, bpm: Double) {
        self.t = t
        self.bpm = bpm
    }
}

/// Coggan's seven power zones, as a share of FTP.
public enum PowerZone: Int, CaseIterable, Sendable, Comparable {
    case z1 = 1, z2, z3, z4, z5, z6, z7

    /// Exclusive lower bound in percent of FTP: a value belongs to a zone when it is strictly above
    /// this bound and not above the next zone's bound. Z1 has none.
    public var lowerPctExclusive: Double {
        switch self {
        case .z1: return -.infinity
        case .z2: return 55
        case .z3: return 75
        case .z4: return 90
        case .z5: return 105
        case .z6: return 120
        case .z7: return 150
        }
    }

    /// English reference name (UI layers localize their own label from the zone number).
    public var referenceName: String {
        switch self {
        case .z1: return "Active recovery"
        case .z2: return "Endurance"
        case .z3: return "Tempo"
        case .z4: return "Threshold"
        case .z5: return "VO2max"
        case .z6: return "Anaerobic"
        case .z7: return "Neuromuscular"
        }
    }

    public static func < (lhs: PowerZone, rhs: PowerZone) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Friel's reading of an aerobic decoupling percentage.
public enum DecouplingVerdict: String, Equatable, Sendable {
    /// Under 5 %.
    case solid
    /// 5 % to 10 %.
    case someDrift
    /// Over 10 %.
    case significant

    public init(percent: Double) {
        if percent < 5 { self = .solid } else if percent <= 10 { self = .someDrift } else { self = .significant }
    }
}

public enum PowerMetrics {
    /// The best-power windows shown on the ride summary: 5 s, 1 min, 5 min, 20 min, 60 min.
    public static let summaryWindows: [Int] = [5, 60, 300, 1200, 3600]
    /// Default warm-up excluded from aerobic decoupling (10 minutes).
    public static let decouplingWarmupSec = 600
    /// Minimum duration after the warm-up for decoupling to be computed (20 minutes).
    public static let decouplingMinSec = 1200

    /// Present, non-negative power values in time order.
    static func powerSeries(_ samples: [MachineSample]) -> [(t: Int, w: Int)] {
        let series: [(t: Int, w: Int)] = samples.compactMap { s in s.powerW.flatMap { $0 >= 0 ? (s.t, $0) : nil } }
        // The recorder appends in time order, so the sort is normally skipped (the live screen calls
        // this every second over the whole ride).
        let ordered = zip(series, series.dropFirst()).allSatisfy { $0.t <= $1.t }
        return ordered ? series : series.sorted { $0.t < $1.t }
    }

    /// Mean power over the samples in the 3 seconds ending at `t` (`t - 2 ... t`). With no `t` the
    /// latest sample's second is used. Nil when no power sample falls in the window.
    public static func threeSecondPower(_ samples: [MachineSample], at t: Int? = nil) -> Double? {
        let series = powerSeries(samples)
        guard let end = t ?? series.last?.t else { return nil }
        let window = series.filter { $0.t <= end && $0.t > end - 3 }
        guard !window.isEmpty else { return nil }
        return Double(window.reduce(0) { $0 + $1.w }) / Double(window.count)
    }

    /// Mean of the present power samples; nil when there are none.
    public static func averagePower(_ samples: [MachineSample]) -> Double? {
        let series = powerSeries(samples)
        guard !series.isEmpty else { return nil }
        return Double(series.reduce(0) { $0 + $1.w }) / Double(series.count)
    }

    /// Highest present power sample.
    public static func maxPower(_ samples: [MachineSample]) -> Int? {
        powerSeries(samples).map(\.w).max()
    }

    /// Normalized Power (Coggan): the 30 s rolling mean of power, each value raised to the 4th power,
    /// averaged, then the 4th root. A rolling value is taken at every power sample from the 30th second
    /// of the series on; its window is the samples present in the 30 seconds ending there, and a window
    /// holding fewer than 15 samples is skipped. Nil with fewer than 30 power samples or no usable window.
    public static func normalizedPower(_ samples: [MachineSample]) -> Double? {
        let series = powerSeries(samples)
        guard series.count >= 30, let first = series.first?.t else { return nil }
        var sum4 = 0.0
        var windows = 0
        var lo = 0
        var windowSum = 0
        for hi in series.indices {
            windowSum += series[hi].w
            let end = series[hi].t
            while series[lo].t <= end - 30 {
                windowSum -= series[lo].w
                lo += 1
            }
            guard end >= first + 29 else { continue }
            let count = hi - lo + 1
            guard count >= 15 else { continue }
            let mean = Double(windowSum) / Double(count)
            sum4 += pow(mean, 4)
            windows += 1
        }
        guard windows > 0 else { return nil }
        return pow(sum4 / Double(windows), 0.25)
    }

    /// Intensity Factor = NP / FTP. Nil without NP or a positive FTP.
    public static func intensityFactor(np: Double?, ftp: Int?) -> Double? {
        guard let np, let ftp, ftp > 0 else { return nil }
        return np / Double(ftp)
    }

    /// Training Stress Score = (seconds x NP x IF) / (FTP x 3600) x 100, where seconds is the count of
    /// power samples (moving seconds).
    public static func tss(_ samples: [MachineSample], ftp: Int?) -> Double? {
        guard let ftp, ftp > 0, let np = normalizedPower(samples),
              let ifactor = intensityFactor(np: np, ftp: ftp) else { return nil }
        let seconds = Double(powerSeries(samples).count)
        return (seconds * np * ifactor) / (Double(ftp) * 3600) * 100
    }

    /// Variability Index = NP / average power.
    public static func variabilityIndex(_ samples: [MachineSample]) -> Double? {
        guard let np = normalizedPower(samples), let avg = averagePower(samples), avg > 0 else { return nil }
        return np / avg
    }

    /// Work in kilojoules: each power sample counts as one second.
    public static func kilojoules(_ samples: [MachineSample]) -> Double {
        Double(powerSeries(samples).reduce(0) { $0 + $1.w }) / 1000
    }

    /// Power as a percentage of FTP; nil without a positive FTP.
    public static func percentFTP(_ watts: Double, ftp: Int?) -> Double? {
        guard let ftp, ftp > 0 else { return nil }
        return watts * 100 / Double(ftp)
    }

    /// The Coggan zone for `watts` at `ftp`. Nil without a positive FTP.
    public static func powerZone(for watts: Double, ftp: Int?) -> PowerZone? {
        guard let pct = percentFTP(watts, ftp: ftp) else { return nil }
        return PowerZone.allCases.last { pct > $0.lowerPctExclusive } ?? .z1
    }

    /// Seconds spent in each zone, Z1 first (seven entries). All zeros without a positive FTP.
    public static func timeInPowerZones(_ samples: [MachineSample], ftp: Int?) -> [Int] {
        var out = Array(repeating: 0, count: PowerZone.allCases.count)
        for s in powerSeries(samples) {
            if let z = powerZone(for: Double(s.w), ftp: ftp) { out[z.rawValue - 1] += 1 }
        }
        return out
    }

    /// Best mean power over `window` consecutive power samples (moving seconds; a pause gap joins the
    /// two sides). Nil when the ride has fewer samples than the window.
    public static func bestPower(_ samples: [MachineSample], window: Int) -> Double? {
        let w = powerSeries(samples).map(\.w)
        guard window > 0, w.count >= window else { return nil }
        var sum = w[0..<window].reduce(0, +)
        var best = sum
        var i = window
        while i < w.count {
            sum += w[i] - w[i - window]
            best = max(best, sum)
            i += 1
        }
        return Double(best) / Double(window)
    }

    /// `bestPower` for each window, in the order given.
    public static func bestPowers(_ samples: [MachineSample], windows: [Int] = summaryWindows) -> [(window: Int, watts: Double?)] {
        windows.map { ($0, bestPower(samples, window: $0)) }
    }

    /// Aerobic decoupling (Pw:HR, Friel) in percent. The first `warmupSec` seconds are dropped, the
    /// rest (up to the last power sample) is split into two equal halves by time, and
    /// decoupling = (ratio1 - ratio2) / ratio1 x 100 with ratio = average power / average HR per half.
    /// Positive means HR rose relative to power. Nil when less than `minSec` remains after the warm-up
    /// or either half lacks power or heart rate.
    public static func decoupling(power samples: [MachineSample], hr: [PowerHRPoint],
                                  warmupSec: Int = decouplingWarmupSec,
                                  minSec: Int = decouplingMinSec) -> Double? {
        let series = powerSeries(samples)
        guard let end = series.last?.t, end - warmupSec >= minSec else { return nil }
        let mid = Double(warmupSec) + Double(end - warmupSec) / 2
        func ratio(_ inFirst: Bool) -> Double? {
            func inHalf(_ t: Int) -> Bool {
                guard t >= warmupSec, t <= end else { return false }
                return inFirst ? Double(t) < mid : Double(t) >= mid
            }
            let p = series.filter { inHalf($0.t) }.map { Double($0.w) }
            let h = hr.filter { inHalf($0.t) && $0.bpm > 0 }.map(\.bpm)
            guard !p.isEmpty, !h.isEmpty else { return nil }
            let avgHR = h.reduce(0, +) / Double(h.count)
            return (p.reduce(0, +) / Double(p.count)) / avgHR
        }
        guard let r1 = ratio(true), let r2 = ratio(false), r1 > 0 else { return nil }
        return (r1 - r2) / r1 * 100
    }

    /// FTP estimate from a ride: 95 % of the best 20 minute power. Nil when shorter than 20 minutes.
    public static func ftpEstimate(_ samples: [MachineSample]) -> Int? {
        bestPower(samples, window: 1200).map { ftpFromTwentyMinute(mean: $0) }
    }

    /// FTP from a 20 minute test mean: 95 % of it, rounded to the nearest watt.
    public static func ftpFromTwentyMinute(mean: Double) -> Int {
        Int((mean * 0.95).rounded())
    }
}

/// Every ride figure the live bike screen and the ride summary show, resolved once from the samples so
/// the two screens cannot disagree about the same number.
public struct RideSummary: Equatable, Sendable {
    public let avgPowerW: Double?
    public let maxPowerW: Int?
    public let normalizedPowerW: Double?
    public let intensityFactor: Double?
    public let tss: Double?
    public let variabilityIndex: Double?
    public let kilojoules: Double
    public let avgCadence: Double?
    /// Aerobic decoupling percent; nil until eligible.
    public let decouplingPct: Double?
    /// Seconds in Z1 ... Z7 (all zero without FTP).
    public let zoneSeconds: [Int]
    /// Best mean power per `PowerMetrics.summaryWindows` entry.
    public let bestPowers: [Int: Double]
    /// Count of power samples (moving seconds).
    public let powerSeconds: Int
    /// The FTP these figures were computed against.
    public let ftpW: Int?

    /// Builds the summary. `hr` is on the sample time axis (seconds from the workout start).
    public init(samples: [MachineSample], hr: [PowerHRPoint], ftp: Int?) {
        let np = PowerMetrics.normalizedPower(samples)
        let avg = PowerMetrics.averagePower(samples)
        let cadence = samples.compactMap(\.cadence)
        avgPowerW = avg
        maxPowerW = PowerMetrics.maxPower(samples)
        normalizedPowerW = np
        intensityFactor = PowerMetrics.intensityFactor(np: np, ftp: ftp)
        tss = PowerMetrics.tss(samples, ftp: ftp)
        variabilityIndex = np.flatMap { n in avg.flatMap { $0 > 0 ? n / $0 : nil } }
        kilojoules = PowerMetrics.kilojoules(samples)
        avgCadence = cadence.isEmpty ? nil : cadence.reduce(0, +) / Double(cadence.count)
        decouplingPct = PowerMetrics.decoupling(power: samples, hr: hr)
        zoneSeconds = PowerMetrics.timeInPowerZones(samples, ftp: ftp)
        var best: [Int: Double] = [:]
        for (window, watts) in PowerMetrics.bestPowers(samples) { if let watts { best[window] = watts } }
        bestPowers = best
        powerSeconds = PowerMetrics.powerSeries(samples).count
        ftpW = ftp
    }

    /// Heart-rate samples (unix seconds) moved onto the sample axis of a workout starting at `startSec`.
    public static func hrPoints(_ hr: [HRSample], startSec: Int) -> [PowerHRPoint] {
        hr.map { PowerHRPoint(t: $0.ts - startSec, bpm: Double($0.bpm)) }
    }
}

/// Figures for one marked lap, derived from the ride's samples at display time (never stored).
public struct LapStats: Equatable, Sendable {
    public let lap: MachineLap
    public let avgPowerW: Double?
    public let normalizedPowerW: Double?
    public let avgHR: Double?
    public let avgCadence: Double?

    /// One entry per lap, in order. `hr` is on the sample time axis.
    public static func compute(laps: [MachineLap], samples: [MachineSample], hr: [PowerHRPoint]) -> [LapStats] {
        laps.map { lap in
            let s = lap.samples(from: samples)
            let h = hr.filter { $0.t >= lap.startT && $0.t < lap.endT && $0.bpm > 0 }.map(\.bpm)
            let c = s.compactMap(\.cadence)
            return LapStats(lap: lap,
                            avgPowerW: PowerMetrics.averagePower(s),
                            normalizedPowerW: PowerMetrics.normalizedPower(s),
                            avgHR: h.isEmpty ? nil : h.reduce(0, +) / Double(h.count),
                            avgCadence: c.isEmpty ? nil : c.reduce(0, +) / Double(c.count))
        }
    }
}
