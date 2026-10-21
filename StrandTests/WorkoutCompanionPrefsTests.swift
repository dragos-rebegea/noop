import XCTest
import Foundation
@testable import Strand

final class WorkoutCompanionPrefsTests: XCTestCase {
    func testDefaultsOnForIndoorSportAndOffForDistanceSport() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let indoor = try XCTUnwrap(WorkoutCatalog.sport(named: "Indoor cycle"))
        let distance = try XCTUnwrap(WorkoutCatalog.sport(named: "Cycling"))

        XCTAssertTrue(WorkoutCompanionPrefs.useCompanion(for: indoor, defaults: defaults))
        XCTAssertFalse(WorkoutCompanionPrefs.useCompanion(for: distance, defaults: defaults))
    }

    func testRemembersChoicePerSport() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let indoor = try XCTUnwrap(WorkoutCatalog.sport(named: "Indoor cycle"))
        let rowing = try XCTUnwrap(WorkoutCatalog.sport(named: "Row machine"))

        WorkoutCompanionPrefs.set(false, for: indoor, defaults: defaults)

        XCTAssertFalse(WorkoutCompanionPrefs.useCompanion(for: indoor, defaults: defaults))
        XCTAssertTrue(WorkoutCompanionPrefs.useCompanion(for: rowing, defaults: defaults))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "WorkoutCompanionPrefsTests." + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }
}
