import XCTest
@testable import StrandNutrition

final class FoodDayTests: XCTestCase {
    func testLocalCalendarDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        // 2026-10-20 23:30 local (UTC+3 in October) is still the 20th, not the next wake day.
        let d = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 30))!
        XCTAssertEqual(FoodDay.key(for: d, calendar: cal), "2026-10-20")
        let early = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 5))!
        XCTAssertEqual(FoodDay.key(for: early, calendar: cal), "2026-10-21")
    }
}
