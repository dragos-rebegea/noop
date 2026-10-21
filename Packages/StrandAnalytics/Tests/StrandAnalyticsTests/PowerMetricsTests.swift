import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class PowerMetricsTests: XCTestCase {

    private func constant(_ watts: Int, seconds: Int, from start: Int = 0) -> [MachineSample] {
        (start..<(start + seconds)).map { MachineSample(t: $0, powerW: watts) }
    }

    func testConstantPowerNPEqualsAverage() {
        let s = constant(200, seconds: 600)
        XCTAssertEqual(PowerMetrics.averagePower(s)!, 200, accuracy: 1e-9)
        XCTAssertEqual(PowerMetrics.normalizedPower(s)!, 200, accuracy: 1e-9)
        XCTAssertEqual(PowerMetrics.variabilityIndex(s)!, 1, accuracy: 1e-9)
        XCTAssertEqual(PowerMetrics.kilojoules(s), 120, accuracy: 1e-9)
        XCTAssertEqual(PowerMetrics.maxPower(s), 200)
    }

    func testAlternatingBlocksNPAboveAverage() {
        // 60 s at 100 W, 60 s at 300 W, twice. Expected value computed independently (Python, the same
        // 30 s windows ending at t = 29 ... 239).
        let s = (0..<240).map { MachineSample(t: $0, powerW: ($0 / 60) % 2 == 0 ? 100 : 300) }
        XCTAssertEqual(PowerMetrics.averagePower(s)!, 200, accuracy: 1e-9)
        XCTAssertEqual(PowerMetrics.normalizedPower(s)!, 241.19321638005087, accuracy: 1e-9)
        XCTAssertGreaterThan(PowerMetrics.variabilityIndex(s)!, 1.2)
    }

    func testFewerThanThirtySamplesHasNoNP() {
        XCTAssertNil(PowerMetrics.normalizedPower(constant(250, seconds: 29)))
        XCTAssertNotNil(PowerMetrics.normalizedPower(constant(250, seconds: 30)))
        XCTAssertNil(PowerMetrics.normalizedPower([]))
    }

    func testGapsAreNotZeroPower() {
        // 200 W with a 30 s pause in the middle: a gap must not pull NP or the average down.
        let s = constant(200, seconds: 60) + constant(200, seconds: 60, from: 90)
        XCTAssertEqual(PowerMetrics.normalizedPower(s)!, 200, accuracy: 1e-9)
        XCTAssertEqual(PowerMetrics.averagePower(s)!, 200, accuracy: 1e-9)
        // Samples without power and negative values are ignored.
        let mixed = s + [MachineSample(t: 200, powerW: nil, cadence: 80), MachineSample(t: 201, powerW: -5)]
        XCTAssertEqual(PowerMetrics.averagePower(mixed)!, 200, accuracy: 1e-9)
    }

    func testSparseWindowsAreSkipped() {
        // Seconds 10 ... 29 missing: the windows straddling the gap hold fewer than 15 samples and are
        // skipped rather than counted as low power.
        var s = constant(200, seconds: 10) + constant(200, seconds: 10, from: 30)
        XCTAssertNil(PowerMetrics.normalizedPower(s), "fewer than 30 power samples")
        s += constant(200, seconds: 20, from: 40)
        XCTAssertEqual(PowerMetrics.normalizedPower(s)!, 200, accuracy: 1e-9)
    }

    func testThreeSecondPower() {
        let s = [MachineSample(t: 0, powerW: 100), MachineSample(t: 1, powerW: 200),
                 MachineSample(t: 2, powerW: 300), MachineSample(t: 3, powerW: 400)]
        XCTAssertEqual(PowerMetrics.threeSecondPower(s)!, 300, accuracy: 1e-9)
        XCTAssertEqual(PowerMetrics.threeSecondPower(s, at: 2)!, 200, accuracy: 1e-9)
        XCTAssertEqual(PowerMetrics.threeSecondPower(s, at: 5)!, 400, accuracy: 1e-9)
        XCTAssertNil(PowerMetrics.threeSecondPower(s, at: 10))
        XCTAssertNil(PowerMetrics.threeSecondPower([]))
    }

    func testIFAndTSSAtFTPForOneHourIsHundred() {
        let s = constant(250, seconds: 3600)
        let np = PowerMetrics.normalizedPower(s)
        XCTAssertEqual(PowerMetrics.intensityFactor(np: np, ftp: 250)!, 1, accuracy: 1e-9)
        XCTAssertEqual(PowerMetrics.tss(s, ftp: 250)!, 100, accuracy: 1e-9)
        // Half an hour at 80 % FTP: TSS = 1800 x 200 x 0.8 / (250 x 3600) x 100 = 32.
        XCTAssertEqual(PowerMetrics.tss(constant(200, seconds: 1800), ftp: 250)!, 32, accuracy: 1e-9)
        XCTAssertNil(PowerMetrics.tss(s, ftp: nil))
        XCTAssertNil(PowerMetrics.tss(s, ftp: 0))
        XCTAssertNil(PowerMetrics.intensityFactor(np: nil, ftp: 250))
    }

    func testZoneBoundaries() {
        let ftp = 200
        func zone(_ pct: Double) -> PowerZone? { PowerMetrics.powerZone(for: Double(ftp) * pct / 100, ftp: ftp) }
        XCTAssertEqual(zone(0), .z1)
        XCTAssertEqual(zone(55), .z1)
        XCTAssertEqual(zone(55.5), .z2)
        XCTAssertEqual(zone(75), .z2)
        XCTAssertEqual(zone(75.5), .z3)
        XCTAssertEqual(zone(90), .z3)
        XCTAssertEqual(zone(91), .z4)
        XCTAssertEqual(zone(105), .z4)
        XCTAssertEqual(zone(106), .z5)
        XCTAssertEqual(zone(120), .z5)
        XCTAssertEqual(zone(121), .z6)
        XCTAssertEqual(zone(150), .z6)
        XCTAssertEqual(zone(151), .z7)
        XCTAssertNil(PowerMetrics.powerZone(for: 100, ftp: nil))
        XCTAssertEqual(PowerZone.z4.referenceName, "Threshold")
    }

    func testTimeInZones() {
        let s = constant(100, seconds: 10) + constant(200, seconds: 5, from: 10) + constant(400, seconds: 2, from: 15)
        // FTP 200: 100 W = 50 % (Z1), 200 W = 100 % (Z4), 400 W = 200 % (Z7).
        XCTAssertEqual(PowerMetrics.timeInPowerZones(s, ftp: 200), [10, 0, 0, 5, 0, 0, 2])
        XCTAssertEqual(PowerMetrics.timeInPowerZones(s, ftp: nil), [0, 0, 0, 0, 0, 0, 0])
    }

    func testBestPowers() {
        // 100 W for 10 min with a 5 s 600 W sprint and a 60 s 300 W effort.
        var s = constant(100, seconds: 600)
        s = s.map { m in
            if (10..<15).contains(m.t) { return MachineSample(t: m.t, powerW: 600) }
            if (300..<360).contains(m.t) { return MachineSample(t: m.t, powerW: 300) }
            return m
        }
        XCTAssertEqual(PowerMetrics.bestPower(s, window: 5)!, 600, accuracy: 1e-9)
        XCTAssertEqual(PowerMetrics.bestPower(s, window: 60)!, 300, accuracy: 1e-9)
        // Best 300 s: the window holding the whole 60 s effort and the sprint cannot both fit; the 60 s
        // effort plus 240 s at 100 W = (60 x 300 + 240 x 100) / 300 = 140.
        XCTAssertEqual(PowerMetrics.bestPower(s, window: 300)!, 140, accuracy: 1e-9)
        let all = PowerMetrics.bestPowers(s)
        XCTAssertEqual(all.map(\.window), [5, 60, 300, 1200, 3600])
        XCTAssertNil(all[3].watts)
        XCTAssertNil(all[4].watts)
    }

    func testDecouplingKnownDrift() {
        let p = constant(200, seconds: 1801)
        let hr = (0...1800).map { PowerHRPoint(t: $0, bpm: $0 < 1200 ? 140 : 150) }
        let d = PowerMetrics.decoupling(power: p, hr: hr)!
        XCTAssertEqual(d, 6.666666666666673, accuracy: 1e-9)
        XCTAssertEqual(DecouplingVerdict(percent: d), .someDrift)
        XCTAssertEqual(DecouplingVerdict(percent: 4.9), .solid)
        XCTAssertEqual(DecouplingVerdict(percent: 10.5), .significant)
    }

    func testDecouplingIneligible() {
        // Only 19 minutes after the warm-up.
        let short = constant(200, seconds: 600 + 1140)
        let hr = (0..<1740).map { PowerHRPoint(t: $0, bpm: 140) }
        XCTAssertNil(PowerMetrics.decoupling(power: short, hr: hr))
        // Long enough but no heart rate in the second half.
        let long = constant(200, seconds: 1801)
        let firstHalfHR = (0..<1200).map { PowerHRPoint(t: $0, bpm: 140) }
        XCTAssertNil(PowerMetrics.decoupling(power: long, hr: firstHalfHR))
        // Steady HR and power: no drift.
        let steady = (0...1800).map { PowerHRPoint(t: $0, bpm: 140) }
        XCTAssertEqual(PowerMetrics.decoupling(power: long, hr: steady)!, 0, accuracy: 1e-9)
    }

    func testFTPEstimate() {
        XCTAssertNil(PowerMetrics.ftpEstimate(constant(250, seconds: 1199)))
        XCTAssertEqual(PowerMetrics.ftpEstimate(constant(250, seconds: 1200)), 238) // 237.5 rounds up
        XCTAssertEqual(PowerMetrics.ftpFromTwentyMinute(mean: 300), 285)
    }
}

final class RideSummaryTests: XCTestCase {
    func testSummaryMatchesTheIndividualMetrics() {
        let s = (0..<1800).map { MachineSample(t: $0, powerW: ($0 / 60) % 2 == 0 ? 150 : 250, cadence: 90) }
        let hr = RideSummary.hrPoints((0..<1800).map { HRSample(ts: 1_000 + $0, bpm: 140) }, startSec: 1_000)
        let r = RideSummary(samples: s, hr: hr, ftp: 250)
        XCTAssertEqual(r.avgPowerW, PowerMetrics.averagePower(s))
        XCTAssertEqual(r.normalizedPowerW, PowerMetrics.normalizedPower(s))
        XCTAssertEqual(r.tss, PowerMetrics.tss(s, ftp: 250))
        XCTAssertEqual(r.variabilityIndex!, PowerMetrics.variabilityIndex(s)!, accuracy: 1e-12)
        XCTAssertEqual(r.kilojoules, 360, accuracy: 1e-9)
        XCTAssertEqual(r.avgCadence, 90)
        XCTAssertEqual(r.zoneSeconds.reduce(0, +), 1800)
        XCTAssertEqual(r.bestPowers[60], 250)
        XCTAssertNil(r.bestPowers[1200 + 2400])
        XCTAssertNil(r.decouplingPct, "t = 0 ... 1799 leaves 1199 s after the warm-up, one short of eligible")
        XCTAssertEqual(r.powerSeconds, 1800)
        XCTAssertEqual(hr.first?.t, 0)
    }
}
