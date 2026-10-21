import Foundation

// Guided training sessions: a fixed, advisory step script laid over a workout's active elapsed time.
//
// PURE. The script only tells the rider what to do next; NOOP never writes to the machine (the rider
// sets resistance on the machine). The step under a given elapsed second, its countdown and the next
// step are plain arithmetic over the step durations, unit-tested in GuidedSessionTests.

/// One step of a guided session.
public struct GuidedStep: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case warmup, hard, easy, test, cooldown
    }

    public let kind: Kind
    public let durationSec: Int

    public init(_ kind: Kind, _ durationSec: Int) {
        self.kind = kind
        self.durationSec = durationSec
    }
}

/// A guided session script.
public enum GuidedSessionKind: String, Codable, Sendable, CaseIterable {
    /// The 20 minute FTP test: 10 min warm-up, 3 x (1 min hard, 1 min easy), 5 min easy, 20 min all-out
    /// test, 10 min cool-down.
    case ftpTest

    public var steps: [GuidedStep] {
        switch self {
        case .ftpTest:
            return [GuidedStep(.warmup, 600),
                    GuidedStep(.hard, 60), GuidedStep(.easy, 60),
                    GuidedStep(.hard, 60), GuidedStep(.easy, 60),
                    GuidedStep(.hard, 60), GuidedStep(.easy, 60),
                    GuidedStep(.easy, 300),
                    GuidedStep(.test, 1200),
                    GuidedStep(.cooldown, 600)]
        }
    }

    public var totalSec: Int { steps.reduce(0) { $0 + $1.durationSec } }

    /// Where `elapsedSec` (active, pause-excluded) falls in the script. Nil once the script has finished
    /// or for a negative time.
    public func position(atElapsed elapsedSec: Int) -> GuidedPosition? {
        guard elapsedSec >= 0 else { return nil }
        var start = 0
        for (index, step) in steps.enumerated() {
            let end = start + step.durationSec
            if elapsedSec < end {
                return GuidedPosition(index: index, step: step, startSec: start,
                                      remainingSec: end - elapsedSec,
                                      next: index + 1 < steps.count ? steps[index + 1] : nil)
            }
            start = end
        }
        return nil
    }

    /// Active-elapsed window `[start, end)` of the first test step, if the script has one.
    public var testWindow: Range<Int>? {
        var start = 0
        for step in steps {
            if step.kind == .test { return start..<(start + step.durationSec) }
            start += step.durationSec
        }
        return nil
    }
}

/// The current step of a guided session.
public struct GuidedPosition: Equatable, Sendable {
    public let index: Int
    public let step: GuidedStep
    /// Active-elapsed second the step began.
    public let startSec: Int
    /// Seconds left in the step.
    public let remainingSec: Int
    /// The step after this one; nil on the last step.
    public let next: GuidedStep?
}

/// Running power mean over a guided test step. Each recorded second counts once.
public struct GuidedTestPower: Codable, Equatable, Sendable {
    public private(set) var sum: Int = 0
    public private(set) var count: Int = 0

    public init() {}

    public mutating func add(_ watts: Int) {
        guard watts >= 0 else { return }
        sum += watts
        count += 1
    }

    public var mean: Double? { count > 0 ? Double(sum) / Double(count) : nil }

    /// FTP from the test (95 % of the mean), only once at least `minSeconds` of power were recorded
    /// (default 15 of the 20 minutes), so a test cut short or mostly without power gives no number.
    public func ftp(minSeconds: Int = 900) -> Int? {
        guard count >= minSeconds, let mean else { return nil }
        return PowerMetrics.ftpFromTwentyMinute(mean: mean)
    }
}
