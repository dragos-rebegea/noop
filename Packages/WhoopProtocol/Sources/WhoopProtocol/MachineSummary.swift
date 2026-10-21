import Foundation

/// One per-second sample captured from an FTMS companion during a workout.
///
/// `t` is the wall-clock offset in seconds from the workout start, so it plots on the same axis as the
/// heart-rate trace. Seconds spent paused carry no sample (the recorder skips them), which is how pause
/// time stays out of the averages.
public struct MachineSample: Codable, Equatable, Sendable {
    public let t: Int
    public let powerW: Int?
    public let cadence: Double?

    public init(t: Int, powerW: Int? = nil, cadence: Double? = nil) {
        self.t = t
        self.powerW = powerW
        self.cadence = cadence
    }
}

extension FTMSReading {
    /// Folds a newer packet into this reading field by field.
    ///
    /// An FTMS machine may split one logical reading over several notifications ("More Data"), each
    /// carrying a subset of fields. A field the newer packet omits keeps its last known value; a field it
    /// carries replaces the old one. A packet from a different machine kind replaces the reading outright.
    public func merging(_ newer: FTMSReading) -> FTMSReading {
        guard newer.kind == kind else { return newer }
        return FTMSReading(kind: kind,
                           speedKmh: newer.speedKmh ?? speedKmh,
                           cadence: newer.cadence ?? cadence,
                           powerWatts: newer.powerWatts ?? powerWatts,
                           distanceM: newer.distanceM ?? distanceM,
                           totalEnergyKcal: newer.totalEnergyKcal ?? totalEnergyKcal,
                           heartRate: newer.heartRate ?? heartRate,
                           elapsedTimeSec: newer.elapsedTimeSec ?? elapsedTimeSec)
    }
}

/// The workout's share of one cumulative machine counter (distance, energy, elapsed time).
///
/// A PM5 reports totals since the machine's own session began, which can predate the workout. The first
/// value seen is the baseline and the total is the growth since. A counter that goes backwards was reset
/// on the machine: the growth so far is banked and counting resumes from the new value. `breakSegment`
/// banks the same way on pause, so counter growth while the workout is paused is not credited.
public struct MachineCounter: Codable, Equatable, Sendable {
    public private(set) var banked: Int = 0
    public private(set) var baseline: Int?
    public private(set) var last: Int?
    public private(set) var seen: Bool = false

    public init() {}

    public mutating func observe(_ value: Int?) {
        guard let value else { return }
        seen = true
        guard let base = baseline, let previous = last else {
            baseline = value
            last = value
            return
        }
        if value < previous {
            banked += max(0, previous - base)
            baseline = value
        }
        last = value
    }

    public mutating func breakSegment() {
        if let base = baseline, let previous = last { banked += max(0, previous - base) }
        baseline = nil
        last = nil
    }

    /// Growth attributed to the workout; nil when the counter was never reported.
    public var total: Int? {
        guard seen else { return nil }
        guard let base = baseline, let previous = last else { return banked }
        return banked + max(0, previous - base)
    }
}

/// The three cumulative machine counters a workout keeps as deltas.
public struct MachineTotals: Codable, Equatable, Sendable {
    public var distanceM = MachineCounter()
    public var energyKcal = MachineCounter()
    public var elapsedS = MachineCounter()

    public init() {}

    public mutating func observe(_ reading: FTMSReading) {
        distanceM.observe(reading.distanceM)
        energyKcal.observe(reading.totalEnergyKcal)
        elapsedS.observe(reading.elapsedTimeSec)
    }

    public mutating func breakSegment() {
        distanceM.breakSegment()
        energyKcal.breakSegment()
        elapsedS.breakSegment()
    }
}

/// Aggregate metrics saved with a workout that used an FTMS companion.
public struct MachineSummary: Codable, Equatable, Sendable {
    public let avgPowerW: Double?
    public let maxPowerW: Int?
    public let avgCadence: Double?
    public let distanceM: Int?
    public let machineEnergyKcal: Int?
    public let elapsedS: Int?

    public init(avgPowerW: Double?, maxPowerW: Int?, avgCadence: Double?, distanceM: Int?,
                machineEnergyKcal: Int?, elapsedS: Int?) {
        self.avgPowerW = avgPowerW
        self.maxPowerW = maxPowerW
        self.avgCadence = avgCadence
        self.distanceM = distanceM
        self.machineEnergyKcal = machineEnergyKcal
        self.elapsedS = elapsedS
    }

    /// Summarizes captured samples. Each sample weighs the same regardless of the gap before it, so a
    /// pause (no samples) does not weight the averages. Missing seconds and fields are not interpolated.
    /// Totals are the workout's counter deltas from `totals`.
    public static func from(samples: [MachineSample], totals: MachineTotals) -> MachineSummary {
        let power = samples.compactMap(\.powerW).filter { $0 >= 0 }
        let cadence = samples.compactMap(\.cadence)
        let avgPower = power.isEmpty ? nil : Double(power.reduce(0, +)) / Double(power.count)
        let avgCadence = cadence.isEmpty ? nil : cadence.reduce(0, +) / Double(cadence.count)

        return MachineSummary(
            avgPowerW: avgPower,
            maxPowerW: power.max(),
            avgCadence: avgCadence,
            distanceM: totals.distanceM.total,
            machineEnergyKcal: totals.energyKcal.total,
            elapsedS: totals.elapsedS.total
        )
    }
}
