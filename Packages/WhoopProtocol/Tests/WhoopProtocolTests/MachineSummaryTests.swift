import XCTest
@testable import WhoopProtocol

final class MachineSummaryTests: XCTestCase {
    private func totals(_ readings: [FTMSReading]) -> MachineTotals {
        var t = MachineTotals()
        readings.forEach { t.observe($0) }
        return t
    }

    func testEmptySamplesProduceOnlyCounterDeltas() {
        let summary = MachineSummary.from(samples: [], totals: totals([
            FTMSReading(kind: .indoorBike, distanceM: 1_000, totalEnergyKcal: 20, elapsedTimeSec: 100),
            FTMSReading(kind: .indoorBike, distanceM: 4_321, totalEnergyKcal: 84, elapsedTimeSec: 901),
        ]))

        XCTAssertNil(summary.avgPowerW)
        XCTAssertNil(summary.maxPowerW)
        XCTAssertNil(summary.avgCadence)
        XCTAssertEqual(summary.distanceM, 3_321)
        XCTAssertEqual(summary.machineEnergyKcal, 64)
        XCTAssertEqual(summary.elapsedS, 801)
    }

    func testPowerGapsAndNegativePowerAreIgnored() {
        let samples = [
            MachineSample(t: 0, powerW: 100),
            MachineSample(t: 1),
            MachineSample(t: 2, powerW: -1),
            MachineSample(t: 3, powerW: 250),
        ]

        let summary = MachineSummary.from(samples: samples, totals: MachineTotals())

        XCTAssertEqual(summary.avgPowerW, 175)
        XCTAssertEqual(summary.maxPowerW, 250)
    }

    func testCadenceMeanUsesPresentSamplesOnly() {
        let samples = [
            MachineSample(t: 0, cadence: 72),
            MachineSample(t: 1),
            MachineSample(t: 2, cadence: 90),
        ]

        let summary = MachineSummary.from(samples: samples, totals: MachineTotals())

        XCTAssertEqual(summary.avgCadence, 81)
    }

    /// `t` is a wall-clock offset, so a pause leaves a gap in `t`; the gap must not weight the means.
    func testPausedTimeGapDoesNotWeightAverages() {
        let samples = [
            MachineSample(t: 10, powerW: 120, cadence: 60),
            MachineSample(t: 130, powerW: 240, cadence: 90),
        ]

        let summary = MachineSummary.from(samples: samples, totals: MachineTotals())

        XCTAssertEqual(summary.avgPowerW, 180)
        XCTAssertEqual(summary.avgCadence, 75)
    }

    func testNoCounterReadingLeavesMachineTotalsAbsent() {
        let summary = MachineSummary.from(samples: [MachineSample(t: 0, powerW: 200)],
                                          totals: totals([FTMSReading(kind: .indoorBike, powerWatts: 200)]))

        XCTAssertNil(summary.distanceM)
        XCTAssertNil(summary.machineEnergyKcal)
        XCTAssertNil(summary.elapsedS)
    }

    func testCounterStartsAtFirstReadingNotAtMachineZero() {
        var c = MachineCounter()
        c.observe(5_000)
        XCTAssertEqual(c.total, 0)
        c.observe(5_250)
        XCTAssertEqual(c.total, 250)
        c.observe(nil)
        XCTAssertEqual(c.total, 250)
    }

    func testCounterResetBanksAndKeepsAccumulatingFromNewBaseline() {
        var c = MachineCounter()
        c.observe(1_000)
        c.observe(1_400)        // +400
        c.observe(3)            // reset on the machine: bank 400, new baseline 3
        XCTAssertEqual(c.total, 400)
        c.observe(103)          // +100 from the new baseline
        XCTAssertEqual(c.total, 500)
        c.observe(0)            // a second reset
        c.observe(50)
        XCTAssertEqual(c.total, 550)
    }

    func testCounterNeverGoesNegative() {
        var c = MachineCounter()
        c.observe(10)
        c.observe(2)
        c.observe(1)
        XCTAssertEqual(c.total, 0)
    }

    func testBreakSegmentExcludesGrowthWhilePaused() {
        var c = MachineCounter()
        c.observe(100)
        c.observe(300)          // +200 before pause
        c.breakSegment()        // paused; the machine keeps counting to 900 unseen
        XCTAssertEqual(c.total, 200)
        c.observe(900)          // first reading after resume is the new baseline
        c.observe(1_000)        // +100 after resume
        XCTAssertEqual(c.total, 300)
    }

    func testCounterRoundTripsThroughJSON() throws {
        var t = MachineTotals()
        t.observe(FTMSReading(kind: .indoorBike, distanceM: 10, totalEnergyKcal: 1, elapsedTimeSec: 5))
        t.observe(FTMSReading(kind: .indoorBike, distanceM: 30, totalEnergyKcal: 2, elapsedTimeSec: 9))
        let decoded = try JSONDecoder().decode(MachineTotals.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(decoded, t)
        XCTAssertEqual(decoded.distanceM.total, 20)
    }

    func testMergingKeepsLastKnownValuePerField() {
        let first = FTMSReading(kind: .indoorBike, speedKmh: 30, powerWatts: 210, distanceM: 500)
        let second = FTMSReading(kind: .indoorBike, cadence: 84, totalEnergyKcal: 12, elapsedTimeSec: 60)

        let merged = first.merging(second)

        XCTAssertEqual(merged, FTMSReading(kind: .indoorBike, speedKmh: 30, cadence: 84, powerWatts: 210,
                                           distanceM: 500, totalEnergyKcal: 12, elapsedTimeSec: 60))
        let third = merged.merging(FTMSReading(kind: .indoorBike, powerWatts: 0))
        XCTAssertEqual(third.powerWatts, 0)
        XCTAssertEqual(third.cadence, 84)
    }

    func testMergingADifferentKindReplacesTheReading() {
        let bike = FTMSReading(kind: .indoorBike, cadence: 80, powerWatts: 200)
        let rower = FTMSReading(kind: .rower, powerWatts: 150)

        XCTAssertEqual(bike.merging(rower), rower)
    }
}
