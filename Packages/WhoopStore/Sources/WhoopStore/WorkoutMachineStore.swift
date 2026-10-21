import Foundation
import GRDB

/// FTMS companion data saved for one workout.
public struct WorkoutMachineRow: Equatable, Codable, Sendable {
    public let deviceId: String
    public let startTs: Int
    public let machineKind: String
    public let machineName: String?
    public let avgPowerW: Double?
    public let maxPowerW: Int?
    public let avgCadence: Double?
    public let distanceM: Int?
    public let energyKcal: Int?
    public let elapsedS: Int?
    public let samplesJSON: String

    public init(deviceId: String, startTs: Int, machineKind: String, machineName: String?,
                avgPowerW: Double?, maxPowerW: Int?, avgCadence: Double?, distanceM: Int?,
                energyKcal: Int?, elapsedS: Int?, samplesJSON: String) {
        self.deviceId = deviceId
        self.startTs = startTs
        self.machineKind = machineKind
        self.machineName = machineName
        self.avgPowerW = avgPowerW
        self.maxPowerW = maxPowerW
        self.avgCadence = avgCadence
        self.distanceM = distanceM
        self.energyKcal = energyKcal
        self.elapsedS = elapsedS
        self.samplesJSON = samplesJSON
    }
}

extension WhoopStore {
    /// Inserts or replaces the FTMS companion data for one workout.
    @discardableResult
    public func upsertWorkoutMachine(_ row: WorkoutMachineRow) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO workoutMachine
                    (deviceId, startTs, machineKind, machineName, avgPowerW, maxPowerW,
                     avgCadence, distanceM, energyKcal, elapsedS, samplesJSON)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, startTs) DO UPDATE SET
                    machineKind = excluded.machineKind,
                    machineName = excluded.machineName,
                    avgPowerW = excluded.avgPowerW,
                    maxPowerW = excluded.maxPowerW,
                    avgCadence = excluded.avgCadence,
                    distanceM = excluded.distanceM,
                    energyKcal = excluded.energyKcal,
                    elapsedS = excluded.elapsedS,
                    samplesJSON = excluded.samplesJSON
                """, arguments: [row.deviceId, row.startTs, row.machineKind, row.machineName,
                                   row.avgPowerW, row.maxPowerW, row.avgCadence, row.distanceM,
                                   row.energyKcal, row.elapsedS, row.samplesJSON])
            return db.changesCount
        }
    }

    /// Copies the FTMS companion data at `fromStartTs` onto `toStartTs` (replacing any row there), for an
    /// edit or merge that moves a workout's natural key. The source row is left in place, mirroring how
    /// RouteStore routes are re-keyed: `deleteWorkouts` drops it once no workout remains at the old key,
    /// so a failed delete keeps both complete versions. Returns true when a row was copied.
    @discardableResult
    public func copyWorkoutMachine(deviceId: String, fromStartTs: Int, toStartTs: Int) async throws -> Bool {
        guard fromStartTs != toStartTs else { return false }
        return try syncWrite { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO workoutMachine
                    (deviceId, startTs, machineKind, machineName, avgPowerW, maxPowerW,
                     avgCadence, distanceM, energyKcal, elapsedS, samplesJSON)
                SELECT deviceId, ?, machineKind, machineName, avgPowerW, maxPowerW,
                       avgCadence, distanceM, energyKcal, elapsedS, samplesJSON
                FROM workoutMachine WHERE deviceId = ? AND startTs = ?
                """, arguments: [toStartTs, deviceId, fromStartTs])
            return db.changesCount > 0
        }
    }

    /// Returns FTMS companion data for the workout identified by device and start time.
    public func workoutMachine(deviceId: String, startTs: Int) async throws -> WorkoutMachineRow? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT deviceId, startTs, machineKind, machineName, avgPowerW, maxPowerW,
                       avgCadence, distanceM, energyKcal, elapsedS, samplesJSON
                FROM workoutMachine WHERE deviceId = ? AND startTs = ?
                """, arguments: [deviceId, startTs]).map {
                    WorkoutMachineRow(
                        deviceId: $0["deviceId"], startTs: $0["startTs"],
                        machineKind: $0["machineKind"], machineName: $0["machineName"],
                        avgPowerW: $0["avgPowerW"], maxPowerW: $0["maxPowerW"],
                        avgCadence: $0["avgCadence"], distanceM: $0["distanceM"],
                        energyKcal: $0["energyKcal"], elapsedS: $0["elapsedS"],
                        samplesJSON: $0["samplesJSON"])
                }
        }
    }
}
