import XCTest
import Foundation
@testable import Strand

final class BikeTrainingPrefsTests: XCTestCase {
    func testDefaultsAndFTPRange() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(BikeTrainingPrefs.ftp(defaults))
        XCTAssertEqual(BikeTrainingPrefs.targetIF(defaults), 0.65...0.72)
        XCTAssertEqual(BikeTrainingPrefs.fuelIntervalMin(defaults), 20)
        XCTAssertEqual(BikeTrainingPrefs.carbsPerHour(defaults), 80)

        BikeTrainingPrefs.setFTP(250, defaults)
        XCTAssertEqual(BikeTrainingPrefs.ftp(defaults), 250)
        BikeTrainingPrefs.setFTP(5_000, defaults)
        XCTAssertNil(BikeTrainingPrefs.ftp(defaults))
    }

    func testTargetBandOrderedAndInWatts() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.8, forKey: BikeTrainingPrefs.targetIFLowKey)
        defaults.set(0.7, forKey: BikeTrainingPrefs.targetIFHighKey)
        let band = BikeTrainingPrefs.targetIF(defaults)
        XCTAssertEqual(band, 0.7...0.8)
        let watts = try XCTUnwrap(BikeTrainingPrefs.targetWatts(ftp: 250, band: band))
        XCTAssertEqual(watts.lowerBound, 175, accuracy: 1e-9)
        XCTAssertEqual(watts.upperBound, 200, accuracy: 1e-9)
        XCTAssertNil(BikeTrainingPrefs.targetWatts(ftp: nil, band: band))
    }

    func testFuelling() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0, forKey: BikeTrainingPrefs.fuelIntervalKey)
        XCTAssertEqual(BikeTrainingPrefs.fuelIntervalMin(defaults), 0)
        XCTAssertEqual(BikeTrainingPrefs.carbsPerReminder(carbsPerHour: 80, intervalMin: 20), 27)
        XCTAssertEqual(BikeTrainingPrefs.carbsPerReminder(carbsPerHour: 90, intervalMin: 20), 30)
        XCTAssertEqual(BikeTrainingPrefs.fuelRemindersDue(elapsedSec: 1199, intervalMin: 20), 0)
        XCTAssertEqual(BikeTrainingPrefs.fuelRemindersDue(elapsedSec: 1200, intervalMin: 20), 1)
        XCTAssertEqual(BikeTrainingPrefs.fuelRemindersDue(elapsedSec: 5000, intervalMin: 0), 0)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "BikeTrainingPrefsTests." + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }
}
