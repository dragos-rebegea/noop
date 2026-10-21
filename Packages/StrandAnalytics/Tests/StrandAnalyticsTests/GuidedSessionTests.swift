import XCTest
@testable import StrandAnalytics

final class GuidedSessionTests: XCTestCase {
    func testFTPTestScript() {
        let s = GuidedSessionKind.ftpTest
        XCTAssertEqual(s.steps.count, 10)
        XCTAssertEqual(s.totalSec, 600 + 6 * 60 + 300 + 1200 + 600)
        XCTAssertEqual(s.testWindow, 1260..<2460)
    }

    func testPositionCountdownAndNext() {
        let s = GuidedSessionKind.ftpTest
        let start = s.position(atElapsed: 0)!
        XCTAssertEqual(start.step.kind, .warmup)
        XCTAssertEqual(start.remainingSec, 600)
        XCTAssertEqual(start.next?.kind, .hard)

        let lastWarmup = s.position(atElapsed: 599)!
        XCTAssertEqual(lastWarmup.index, 0)
        XCTAssertEqual(lastWarmup.remainingSec, 1)

        let firstHard = s.position(atElapsed: 600)!
        XCTAssertEqual(firstHard.index, 1)
        XCTAssertEqual(firstHard.step, GuidedStep(.hard, 60))
        XCTAssertEqual(firstHard.startSec, 600)

        let test = s.position(atElapsed: 1260)!
        XCTAssertEqual(test.step.kind, .test)
        XCTAssertEqual(test.remainingSec, 1200)
        XCTAssertEqual(test.next?.kind, .cooldown)

        let cooldown = s.position(atElapsed: 2460)!
        XCTAssertEqual(cooldown.step.kind, .cooldown)
        XCTAssertNil(cooldown.next)

        XCTAssertNil(s.position(atElapsed: s.totalSec))
        XCTAssertNil(s.position(atElapsed: -1))
    }

    func testTestPowerMeanAndFTP() {
        var p = GuidedTestPower()
        XCTAssertNil(p.mean)
        for _ in 0..<899 { p.add(300) }
        p.add(-10)
        XCTAssertEqual(p.count, 899)
        XCTAssertNil(p.ftp(), "under 15 minutes of power")
        p.add(300)
        XCTAssertEqual(p.mean, 300)
        XCTAssertEqual(p.ftp(), 285)
    }
}
