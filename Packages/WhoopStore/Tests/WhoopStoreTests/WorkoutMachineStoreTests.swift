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
}
