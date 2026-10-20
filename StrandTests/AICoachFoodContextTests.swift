import XCTest
import StrandNutrition
import WhoopStore
@testable import Strand

@MainActor
final class AICoachFoodContextTests: XCTestCase {
    private func row(_ day: String, _ name: String, _ grams: Double?, _ k: Double, _ p: Double, _ c: Double, _ f: Double,
                     at: Int = 0) -> FoodEntryRow {
        FoodEntryRow(id: UUID().uuidString, deviceId: FoodLog.deviceId, day: day, loggedAt: at, name: name, grams: grams,
                     kcal: k, proteinG: p, carbsG: c, fatG: f, source: "quick", productId: nil)
    }

    func testNilWhenNothingLogged() {
        XCTAssertNil(AICoachEngine.foodLogSummary(entries: [], today: "2026-10-20",
                                                  targets: Macros(kcal: 0, protein: 0, carbs: 0, fat: 0)))
    }

    func testTodayItemsTotalsTargetsAndHistory() {
        let entries = [
            row("2026-10-18", "Oats", 80, 300, 10, 50, 5),
            row("2026-10-20", "Chicken breast", 150, 248, 46.5, 0, 5.4, at: 1_760_950_800),
            row("2026-10-20", "Rice", 200, 260, 5.4, 56, 0.6, at: 1_760_951_000),
        ]
        let s = AICoachEngine.foodLogSummary(entries: entries, today: "2026-10-20",
                                             targets: Macros(kcal: 2400, protein: 180, carbs: 250, fat: 70))!
        XCTAssertTrue(s.hasPrefix("Food log (logged in NOOP):"))
        XCTAssertTrue(s.contains("Today so far: 508 kcal, protein 52 g, carbs 56 g, fat 6 g"))
        XCTAssertTrue(s.contains("Daily targets: 2400 kcal, protein 180 g, carbs 250 g, fat 70 g"))
        XCTAssertTrue(s.contains("Chicken breast 150 g"))
        XCTAssertTrue(s.contains("2026-10-18: 300 kcal, P 10, C 50, F 5"))
        XCTAssertFalse(s.contains("2026-10-19"))
    }

    func testTargetsOmittedWhenUnset() {
        let s = AICoachEngine.foodLogSummary(entries: [row("2026-10-20", "Apple", 150, 78, 0.4, 21, 0.3)],
                                             today: "2026-10-20", targets: Macros(kcal: 0, protein: 0, carbs: 0, fat: 0))!
        XCTAssertFalse(s.contains("Daily targets"))
    }
}
