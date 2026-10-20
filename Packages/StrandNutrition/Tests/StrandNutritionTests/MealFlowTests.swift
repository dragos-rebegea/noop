import XCTest
@testable import StrandNutrition

final class MealSlotTests: XCTestCase {
    func testSlotBoundaries() {
        XCTAssertEqual(MealSlot.slot(forHour: 4), .snack)
        XCTAssertEqual(MealSlot.slot(forHour: 5), .breakfast)
        XCTAssertEqual(MealSlot.slot(forHour: 10), .breakfast)
        XCTAssertEqual(MealSlot.slot(forHour: 11), .lunch)
        XCTAssertEqual(MealSlot.slot(forHour: 15), .lunch)
        XCTAssertEqual(MealSlot.slot(forHour: 16), .dinner)
        XCTAssertEqual(MealSlot.slot(forHour: 21), .dinner)
        XCTAssertEqual(MealSlot.slot(forHour: 22), .snack)
        XCTAssertEqual(MealSlot.slot(forHour: 0), .snack)
    }

    func testDayOrder() {
        XCTAssertEqual(MealSlot.allCases, [.breakfast, .lunch, .dinner, .snack])
    }

    func testSlotForDateUsesCalendarHour() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12, minute: 30))!
        XCTAssertEqual(MealSlot.slot(for: date, calendar: cal), .lunch)
    }
}

final class PortionStepTests: XCTestCase {
    func testStepSizeBySize() {
        XCTAssertEqual(PortionStep.next(45, up: true), 50)
        XCTAssertEqual(PortionStep.next(50, up: true), 60)
        XCTAssertEqual(PortionStep.next(190, up: true), 200)
        XCTAssertEqual(PortionStep.next(200, up: true), 225)
    }

    func testDownIsSymmetricWithUp() {
        XCTAssertEqual(PortionStep.next(50, up: false), 45)
        XCTAssertEqual(PortionStep.next(60, up: false), 50)
        XCTAssertEqual(PortionStep.next(200, up: false), 190)
        XCTAssertEqual(PortionStep.next(225, up: false), 200)
    }

    func testOffGridValuesSnapToTheNextStep() {
        XCTAssertEqual(PortionStep.next(137, up: true), 140)
        XCTAssertEqual(PortionStep.next(137, up: false), 130)
        XCTAssertEqual(PortionStep.next(212, up: true), 225)
        XCTAssertEqual(PortionStep.next(212, up: false), 200)
    }

    func testNeverBelowFive() {
        XCTAssertEqual(PortionStep.next(5, up: false), 5)
        XCTAssertEqual(PortionStep.next(7, up: false), 5)
        XCTAssertEqual(PortionStep.next(2, up: false), 5)
    }

    func testScaled() {
        XCTAssertEqual(PortionStep.scaled(150, by: 0.5), 75)
        XCTAssertEqual(PortionStep.scaled(150, by: 2), 300)
        XCTAssertEqual(PortionStep.scaled(137, by: 1), 135)
        XCTAssertEqual(PortionStep.scaled(33, by: 0.5), 15)
        XCTAssertEqual(PortionStep.scaled(6, by: 0.5), 5)
        XCTAssertEqual(PortionStep.scaled(0, by: 1), 5)
    }
}

final class TimeOfDaySuggestionsTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// Oats most mornings, pasta more often but in the evening, a coffee once at 9.
    private var fixture: [(name: String, productId: String?, loggedAt: Date)] {
        [
            ("Oats", nil, at(10, 7, 30)),       // 0
            ("Pasta", nil, at(10, 19)),         // 1
            ("oats", nil, at(11, 8)),           // 2 same food as 0 (case-insensitive)
            ("Pasta", nil, at(11, 20)),         // 3
            ("Pasta", nil, at(12, 19, 30)),     // 4
            ("Oats", nil, at(13, 7)),           // 5 latest oats
            ("Pasta", nil, at(13, 19)),         // 6
            ("Pasta", nil, at(14, 18, 45)),     // 7 latest pasta
            ("Coffee", "123", at(14, 9)),       // 8
        ]
    }

    func testMorningPrefersMorningFoods() {
        let r = TimeOfDaySuggestions.rank(fixture, now: at(15, 8), calendar: cal, limit: 8)
        // Oats: 3 near 8:00; coffee: 1 near; pasta: 0 near but 5 overall.
        XCTAssertEqual(r, [5, 8, 7])
    }

    func testEveningPrefersEveningFoods() {
        let r = TimeOfDaySuggestions.rank(fixture, now: at(15, 19), calendar: cal, limit: 8)
        // Pasta: 5 near 19:00; then by overall frequency oats (3) over coffee (1).
        XCTAssertEqual(r, [7, 5, 8])
    }

    func testLimit() {
        XCTAssertEqual(TimeOfDaySuggestions.rank(fixture, now: at(15, 19), calendar: cal, limit: 1), [7])
        XCTAssertEqual(TimeOfDaySuggestions.rank(fixture, now: at(15, 19), calendar: cal, limit: 0), [])
    }

    func testProductIdSeparatesFoods() {
        let entries: [(name: String, productId: String?, loggedAt: Date)] = [
            ("Yogurt", "1", at(10, 8)),
            ("Yogurt", "2", at(11, 8)),
        ]
        XCTAssertEqual(TimeOfDaySuggestions.rank(entries, now: at(15, 8), calendar: cal, limit: 8), [1, 0])
    }

    func testRecencyBreaksTies() {
        let entries: [(name: String, productId: String?, loggedAt: Date)] = [
            ("Apple", nil, at(10, 12)),
            ("Banana", nil, at(11, 12)),
        ]
        XCTAssertEqual(TimeOfDaySuggestions.rank(entries, now: at(15, 12), calendar: cal, limit: 8), [1, 0])
    }

    func testWindowWrapsAroundMidnight() {
        let entries: [(name: String, productId: String?, loggedAt: Date)] = [
            ("Late toast", nil, at(10, 23)),
            ("Lunch salad", nil, at(11, 12)),
            ("Lunch salad", nil, at(12, 12)),
        ]
        // 23:00 is within 2 h of 00:30, so the single toast outranks the more frequent salad.
        XCTAssertEqual(TimeOfDaySuggestions.rank(entries, now: at(15, 0, 30), calendar: cal, limit: 8), [0, 2])
    }

    func testEmpty() {
        XCTAssertEqual(TimeOfDaySuggestions.rank([], now: at(15, 8), calendar: cal, limit: 8), [])
    }
}
