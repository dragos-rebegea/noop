import XCTest
@testable import StrandNutrition

final class PlausibilityTests: XCTestCase {
    func testRealFoodsPass() {
        // Oats, chicken breast, olive oil, cucumber (low-kcal edge: 40 kcal floor).
        XCTAssertEqual(Plausibility.issues(MacroPer100g(kcal: 389, protein: 16.9, carbs: 66.3, fat: 6.9)), [])
        XCTAssertEqual(Plausibility.issues(MacroPer100g(kcal: 165, protein: 31, carbs: 0, fat: 3.6)), [])
        XCTAssertEqual(Plausibility.issues(MacroPer100g(kcal: 884, protein: 0, carbs: 0, fat: 100)), [])
        XCTAssertEqual(Plausibility.issues(MacroPer100g(kcal: 15, protein: 0.7, carbs: 3.6, fat: 0.1)), [])
    }

    func testNegative() {
        XCTAssertEqual(Plausibility.issues(MacroPer100g(kcal: 100, protein: -1, carbs: 20, fat: 1)),
                       [.negativeValue])
    }

    func testMassOver100() {
        let issues = Plausibility.issues(MacroPer100g(kcal: 600, protein: 60, carbs: 50, fat: 10))
        XCTAssertTrue(issues.contains(.macroMassOver100))
    }

    func testEnergyMismatch() {
        // Macros imply 4*20 + 4*10 + 9*5 = 165 kcal; 400 is far outside max(40, 0.25 * 400).
        XCTAssertEqual(Plausibility.issues(MacroPer100g(kcal: 400, protein: 20, carbs: 10, fat: 5)),
                       [.energyMismatch(expectedKcal: 165)])
    }

    func testEnergyWithinTolerancePasses() {
        // Implied 165, stated 200: diff 35 <= max(40, 50).
        XCTAssertEqual(Plausibility.issues(MacroPer100g(kcal: 200, protein: 20, carbs: 10, fat: 5)), [])
    }
}
