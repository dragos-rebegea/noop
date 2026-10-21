import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

final class BikeLiveTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testBikeRideNeedsCompanionIndoorBikeAndPower() {
        var w = AppModel.ActiveWorkout(start: start, sport: "Indoor cycle", usesCompanion: true)
        XCTAssertFalse(w.isBikeRide)
        w.lastMachineReading = FTMSReading(kind: .indoorBike, cadence: 80)
        w.machineSamples = [MachineSample(t: 0, powerW: nil, cadence: 80)]
        XCTAssertFalse(w.isBikeRide, "no power yet")
        w.machineSamples.append(MachineSample(t: 1, powerW: 150, cadence: 82))
        XCTAssertTrue(w.isBikeRide)
        w.lastMachineReading = FTMSReading(kind: .rower, powerWatts: 150)
        XCTAssertFalse(w.isBikeRide, "a rower keeps the standard layout")
    }

    func testFuelReminderFiresOncePerIntervalAndExcludesPause() {
        var w = AppModel.ActiveWorkout(start: start, sport: "Indoor cycle", usesCompanion: true)
        XCTAssertFalse(w.checkFuelReminder(intervalMin: 20, at: start.addingTimeInterval(1_199)))
        XCTAssertTrue(w.checkFuelReminder(intervalMin: 20, at: start.addingTimeInterval(1_200)))
        XCTAssertFalse(w.checkFuelReminder(intervalMin: 20, at: start.addingTimeInterval(1_260)))
        XCTAssertTrue(w.fuelReminderPending)
        w.fuelRemindersSeen = w.fuelRemindersFired
        XCTAssertFalse(w.fuelReminderPending)
        // Ten paused minutes push the second reminder back by ten minutes.
        w.pausedDuration = 600
        XCTAssertFalse(w.checkFuelReminder(intervalMin: 20, at: start.addingTimeInterval(2_400)))
        XCTAssertTrue(w.checkFuelReminder(intervalMin: 20, at: start.addingTimeInterval(3_000)))
        XCTAssertFalse(w.checkFuelReminder(intervalMin: 0, at: start.addingTimeInterval(9_000)), "off")
    }

    func testTargetBandPosition() {
        XCTAssertEqual(TargetBandPosition.resolve(watts: 150, band: 160...180), .below)
        XCTAssertEqual(TargetBandPosition.resolve(watts: 160, band: 160...180), .inside)
        XCTAssertEqual(TargetBandPosition.resolve(watts: 180, band: 160...180), .inside)
        XCTAssertEqual(TargetBandPosition.resolve(watts: 181, band: 160...180), .above)
    }

    func testFuelCountersRoundTripInSnapshot() {
        let snap = ActiveWorkoutPersistence.Snapshot(
            startSec: 1_000_000, sport: "Indoor cycle", samples: [], avgHr: 0, peakHr: 0, liveStrain: 0,
            fuelRemindersFired: 2, fuelRemindersSeen: 1)
        XCTAssertEqual(ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(snap)), snap)
    }

    func testDetailShowsRideSummaryOnlyForBikeWithPower() {
        func row(_ kind: String) -> WorkoutMachineRow {
            WorkoutMachineRow(deviceId: "d", startTs: 1, machineKind: kind, machineName: nil, avgPowerW: nil,
                              maxPowerW: nil, avgCadence: nil, distanceM: nil, energyKcal: nil, elapsedS: nil,
                              samplesJSON: "[]")
        }
        let power = [MachineSample(t: 0, powerW: 120)]
        XCTAssertTrue(WorkoutDetailView.isBikeRide(row("indoorBike"), samples: power))
        XCTAssertFalse(WorkoutDetailView.isBikeRide(row("rower"), samples: power))
        XCTAssertFalse(WorkoutDetailView.isBikeRide(row("indoorBike"), samples: [MachineSample(t: 0, cadence: 80)]))
        XCTAssertFalse(WorkoutDetailView.isBikeRide(nil, samples: power))
    }
}
