import XCTest
@testable import StrandNutrition

final class MacrosTests: XCTestCase {
    func testScaledByGrams() {
        let oats = MacroPer100g(kcal: 389, protein: 16.9, carbs: 66.3, fat: 6.9)
        let m = oats.scaled(grams: 50)
        XCTAssertEqual(m.kcal, 194.5, accuracy: 1e-9)
        XCTAssertEqual(m.protein, 8.45, accuracy: 1e-9)
        XCTAssertEqual(m.carbs, 33.15, accuracy: 1e-9)
        XCTAssertEqual(m.fat, 3.45, accuracy: 1e-9)
    }

    func testZeroGramsIsZero() {
        XCTAssertEqual(MacroPer100g(kcal: 100, protein: 1, carbs: 2, fat: 3).scaled(grams: 0), .zero)
    }

    func testSum() {
        let a = Macros(kcal: 100, protein: 10, carbs: 5, fat: 2)
        let b = Macros(kcal: 50, protein: 1, carbs: 10, fat: 1)
        XCTAssertEqual([a, b].sum(), Macros(kcal: 150, protein: 11, carbs: 15, fat: 3))
        XCTAssertEqual([Macros]().sum(), .zero)
    }
}
