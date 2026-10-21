import XCTest
import GRDB
@testable import WhoopStore

final class WorkoutMachineStoreTests: XCTestCase {
    func testV49CreatesWorkoutMachineTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        let columns = try await store.columnNamesForTest(table: "workoutMachine")
        let primaryKey = try await store.primaryKeyColumns("workoutMachine")

        XCTAssertTrue(tables.contains("workoutMachine"))
        XCTAssertEqual(columns, [
            "deviceId", "startTs", "machineKind", "machineName", "avgPowerW", "maxPowerW",
            "avgCadence", "distanceM", "energyKcal", "elapsedS", "samplesJSON",
        ])
        XCTAssertEqual(primaryKey, ["deviceId", "startTs"])
        XCTAssertTrue(DeviceRegistryStore.deviceScopedTables.contains("workoutMachine"))
    }

    func testV49IsAdditiveOnTopOfV48() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v48-food-log")
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO workout
                    (deviceId, startTs, endTs, sport, source)
                VALUES ('dev', 100, 200, 'cycling', 'manual')
                """)
        }

        try WhoopStore.makeMigrator().migrate(dbQueue)

        let count = try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workout WHERE deviceId = 'dev'")
        }
        XCTAssertEqual(count, 1)
    }

    func testWorkoutMachineRoundTripsAndUpserts() async throws {
        let store = try await WhoopStore.inMemory()
        let original = WorkoutMachineRow(
            deviceId: "dev", startTs: 100, machineKind: "indoorBike", machineName: "Bike",
            avgPowerW: 182.5, maxPowerW: 410, avgCadence: 86.25, distanceM: 12_345,
            energyKcal: 321, elapsedS: 2_700,
            samplesJSON: #"[{"t":0,"powerW":180,"cadence":85}]"#)

        let inserted = try await store.upsertWorkoutMachine(original)
        let readOriginal = try await store.workoutMachine(deviceId: "dev", startTs: 100)
        XCTAssertEqual(inserted, 1)
        XCTAssertEqual(readOriginal, original)

        let updated = WorkoutMachineRow(
            deviceId: "dev", startTs: 100, machineKind: "indoorBike", machineName: nil,
            avgPowerW: 190, maxPowerW: 430, avgCadence: nil, distanceM: 13_000,
            energyKcal: nil, elapsedS: 2_800, samplesJSON: "[]")
        let changed = try await store.upsertWorkoutMachine(updated)
        let readUpdated = try await store.workoutMachine(deviceId: "dev", startTs: 100)
        let missing = try await store.workoutMachine(deviceId: "other", startTs: 100)
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(readUpdated, updated)
        XCTAssertNil(missing)
    }

    func testDeletingWorkoutAlsoDeletesMachineData() async throws {
        let store = try await WhoopStore.inMemory()
        let workout = WorkoutRow(
            startTs: 100, endTs: 200, sport: "cycling", source: "manual", durationS: 100,
            energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
            zonesJSON: nil, notes: nil, steps: nil)
        try await store.upsertWorkouts([workout], deviceId: "dev")
        try await store.upsertWorkoutMachine(WorkoutMachineRow(
            deviceId: "dev", startTs: 100, machineKind: "indoorBike", machineName: nil,
            avgPowerW: nil, maxPowerW: nil, avgCadence: nil, distanceM: nil,
            energyKcal: nil, elapsedS: nil, samplesJSON: "[]"))

        let deleted = try await store.deleteWorkouts(deviceId: "dev", sport: "cycling", from: 100, to: 100)
        let machine = try await store.workoutMachine(deviceId: "dev", startTs: 100)
        XCTAssertEqual(deleted, 1)
        XCTAssertNil(machine)
    }

    private func workout(_ startTs: Int, _ sport: String) -> WorkoutRow {
        WorkoutRow(startTs: startTs, endTs: startTs + 100, sport: sport, source: "manual", durationS: 100,
                   energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                   zonesJSON: nil, notes: nil, steps: nil)
    }

    private func machine(_ startTs: Int, samples: String = "[]") -> WorkoutMachineRow {
        WorkoutMachineRow(deviceId: "dev", startTs: startTs, machineKind: "indoorBike", machineName: "Bike",
                          avgPowerW: 200, maxPowerW: 300, avgCadence: 85, distanceM: 1_000,
                          energyKcal: 50, elapsedS: 600, samplesJSON: samples)
    }

    /// The sport edit path: upsert the new sport at the same startTs, then delete the old sport.
    func testSportEditKeepsMachineData() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertWorkouts([workout(100, "cycling")], deviceId: "dev")
        try await store.upsertWorkoutMachine(machine(100))

        try await store.upsertWorkouts([workout(100, "indoor cycling")], deviceId: "dev")
        let deleted = try await store.deleteWorkouts(deviceId: "dev", sport: "cycling", from: 100, to: 100)

        XCTAssertEqual(deleted, 1)
        let kept = try await store.workoutMachine(deviceId: "dev", startTs: 100)
        XCTAssertEqual(kept, machine(100))
    }

    /// The start-time edit path: upsert the replacement, copy the machine row, then delete the old row.
    func testStartTimeEditMovesMachineData() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertWorkouts([workout(100, "cycling")], deviceId: "dev")
        try await store.upsertWorkoutMachine(machine(100, samples: #"[{"t":0,"powerW":180}]"#))

        try await store.upsertWorkouts([workout(160, "cycling")], deviceId: "dev")
        let copied = try await store.copyWorkoutMachine(deviceId: "dev", fromStartTs: 100, toStartTs: 160)
        try await store.deleteWorkouts(deviceId: "dev", sport: "cycling", from: 100, to: 100)

        XCTAssertTrue(copied)
        let old = try await store.workoutMachine(deviceId: "dev", startTs: 100)
        let moved = try await store.workoutMachine(deviceId: "dev", startTs: 160)
        XCTAssertNil(old)
        XCTAssertEqual(moved?.samplesJSON, #"[{"t":0,"powerW":180}]"#)
        XCTAssertEqual(moved?.startTs, 160)
    }

    /// The #64 merge path: the merged row takes the earliest start; the later original's machine row is
    /// copied onto the merged key and the originals are retired.
    func testMergeCarriesMachineDataOntoMergedKey() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertWorkouts([workout(100, "walk"), workout(300, "cycling")], deviceId: "dev")
        try await store.upsertWorkoutMachine(machine(300, samples: "[1]"))

        try await store.upsertWorkouts([workout(100, "cycling")], deviceId: "dev")   // merged row
        try await store.copyWorkoutMachine(deviceId: "dev", fromStartTs: 300, toStartTs: 100)
        try await store.deleteWorkouts(deviceId: "dev", sport: "walk", from: 100, to: 100)
        try await store.deleteWorkouts(deviceId: "dev", sport: "cycling", from: 300, to: 300)

        let merged = try await store.workoutMachine(deviceId: "dev", startTs: 100)
        let stale = try await store.workoutMachine(deviceId: "dev", startTs: 300)
        XCTAssertEqual(merged?.samplesJSON, "[1]")
        XCTAssertNil(stale)
    }

    func testCopyWithoutSourceRowCopiesNothing() async throws {
        let store = try await WhoopStore.inMemory()
        let copied = try await store.copyWorkoutMachine(deviceId: "dev", fromStartTs: 1, toStartTs: 2)
        let sameKey = try await store.copyWorkoutMachine(deviceId: "dev", fromStartTs: 1, toStartTs: 1)
        XCTAssertFalse(copied)
        XCTAssertFalse(sameKey)
    }
}
