import XCTest
@testable import WhoopProtocol

final class MachineSummaryTests: XCTestCase {
    func testEmptySamplesProduceOnlyLastReadingTotals() {
        let reading = FTMSReading(kind: .indoorBike, distanceM: 4_321,
                                  totalEnergyKcal: 84, elapsedTimeSec: 901)

        let summary = MachineSummary.from(samples: [], lastReading: reading)

        XCTAssertNil(summary.avgPowerW)
        XCTAssertNil(summary.maxPowerW)
        XCTAssertNil(summary.avgCadence)
        XCTAssertEqual(summary.distanceM, 4_321)
        XCTAssertEqual(summary.machineEnergyKcal, 84)
        XCTAssertEqual(summary.elapsedS, 901)
    }

    func testPowerGapsAndNegativePowerAreIgnored() {
        let samples = [
            MachineSample(t: 0, powerW: 100),
            MachineSample(t: 1),
            MachineSample(t: 2, powerW: -1),
            MachineSample(t: 3, powerW: 250),
        ]

        let summary = MachineSummary.from(samples: samples, lastReading: nil)

        XCTAssertEqual(summary.avgPowerW, 175)
        XCTAssertEqual(summary.maxPowerW, 250)
    }

    func testCadenceMeanUsesPresentSamplesOnly() {
        let samples = [
            MachineSample(t: 0, cadence: 72),
            MachineSample(t: 1),
            MachineSample(t: 2, cadence: 90),
        ]

        let summary = MachineSummary.from(samples: samples, lastReading: nil)

        XCTAssertEqual(summary.avgCadence, 81)
    }

    func testPausedTimeGapDoesNotWeightAverages() {
        let samples = [
            MachineSample(t: 10, powerW: 120, cadence: 60),
            MachineSample(t: 130, powerW: 240, cadence: 90),
        ]

        let summary = MachineSummary.from(samples: samples, lastReading: nil)

        XCTAssertEqual(summary.avgPowerW, 180)
        XCTAssertEqual(summary.avgCadence, 75)
    }

    func testNoReadingLeavesMachineTotalsAbsent() {
        let summary = MachineSummary.from(samples: [MachineSample(t: 0, powerW: 200)],
                                          lastReading: nil)

        XCTAssertNil(summary.distanceM)
        XCTAssertNil(summary.machineEnergyKcal)
        XCTAssertNil(summary.elapsedS)
    }
}
