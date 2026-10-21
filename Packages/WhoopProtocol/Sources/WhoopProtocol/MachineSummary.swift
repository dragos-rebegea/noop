import Foundation

/// One active-second sample captured from an FTMS companion during a workout.
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

    /// Summarizes captured active seconds. Missing seconds and missing fields are not interpolated.
    public static func from(samples: [MachineSample], lastReading: FTMSReading?) -> MachineSummary {
        let power = samples.compactMap(\.powerW).filter { $0 >= 0 }
        let cadence = samples.compactMap(\.cadence)
        let avgPower = power.isEmpty ? nil : Double(power.reduce(0, +)) / Double(power.count)
        let avgCadence = cadence.isEmpty ? nil : cadence.reduce(0, +) / Double(cadence.count)

        return MachineSummary(
            avgPowerW: avgPower,
            maxPowerW: power.max(),
            avgCadence: avgCadence,
            distanceM: lastReading?.distanceM,
            machineEnergyKcal: lastReading?.totalEnergyKcal,
            elapsedS: lastReading?.elapsedTimeSec
        )
    }
}
