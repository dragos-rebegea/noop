import XCTest
import WhoopProtocol
import StrandAnalytics
@testable import Strand

final class GuidedFTPTestTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_000)
    private func at(_ s: Int) -> Date { start.addingTimeInterval(TimeInterval(s)) }

    func testStepAnnouncementsSkipTheStartAndFireOnEachChange() {
        var w = AppModel.ActiveWorkout(start: start, sport: "Indoor cycle", usesCompanion: true, guided: .ftpTest)
        XCTAssertFalse(w.advanceGuided(at: at(0)), "the start buzz already covers step 1")
        XCTAssertFalse(w.advanceGuided(at: at(599)))
        XCTAssertTrue(w.advanceGuided(at: at(600)))
        XCTAssertFalse(w.advanceGuided(at: at(601)))
        XCTAssertTrue(w.advanceGuided(at: at(3_060)), "script finished")
        XCTAssertEqual(w.guidedStepIndex, GuidedSessionKind.ftpTest.steps.count)

        var plain = AppModel.ActiveWorkout(start: start, sport: "Indoor cycle")
        XCTAssertFalse(plain.advanceGuided(at: at(600)))
    }

    func testOnlyTestStepPowerCountsAndFTPWaitsForTheEndOfTheTest() {
        var w = AppModel.ActiveWorkout(start: start, sport: "Indoor cycle", usesCompanion: true, guided: .ftpTest)
        w.recordGuidedPower(400, at: at(700))          // a hard minute, not the test
        for s in 1_260..<2_460 { w.recordGuidedPower(260, at: at(s)) }
        w.recordGuidedPower(100, at: at(2_500))        // cool-down
        XCTAssertEqual(w.guidedTestPower.count, 1_200)
        XCTAssertEqual(w.guidedTestPower.mean, 260)
        XCTAssertNil(w.pendingGuidedFTP(at: at(2_459)), "test still running")
        XCTAssertEqual(w.pendingGuidedFTP(at: at(2_460)), 247)
        w.guidedFTPOffered = true
        XCTAssertNil(w.pendingGuidedFTP(at: at(2_460)))
    }

    func testCutShortTestGivesNoFTP() {
        var w = AppModel.ActiveWorkout(start: start, sport: "Indoor cycle", usesCompanion: true, guided: .ftpTest)
        for s in 1_260..<1_800 { w.recordGuidedPower(260, at: at(s)) }
        XCTAssertNil(w.pendingGuidedFTP(at: at(2_460)), "only 9 minutes of test power")
    }

    func testGuidedStateRoundTripsInSnapshot() {
        var power = GuidedTestPower()
        power.add(250)
        let snap = ActiveWorkoutPersistence.Snapshot(
            startSec: 2_000_000, sport: "Indoor cycle", samples: [], avgHr: 0, peakHr: 0, liveStrain: 0,
            guided: .ftpTest, guidedStepIndex: 3, guidedTestPower: power, guidedFTPOffered: false)
        XCTAssertEqual(ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(snap)), snap)
    }

    func testFTPTestOfferedForIndoorCycleOnly() throws {
        XCTAssertTrue(WorkoutSelectionScreen.offersFTPTest(try XCTUnwrap(WorkoutCatalog.sport(named: "Indoor cycle"))))
        XCTAssertFalse(WorkoutSelectionScreen.offersFTPTest(try XCTUnwrap(WorkoutCatalog.sport(named: "Cycling"))))
    }
}
