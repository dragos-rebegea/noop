import XCTest
@testable import StrandNutrition

final class MacroProgressTests: XCTestCase {
    func testFraction() {
        XCTAssertEqual(MacroProgress.fraction(52, target: 180), 0.2889, accuracy: 0.0001)
        XCTAssertEqual(MacroProgress.fraction(10, target: 0), 0)
        XCTAssertEqual(MacroProgress.fraction(300, target: 180), 1)
    }

    func testFilledDots() {
        XCTAssertEqual(MacroProgress.filledDots(52, target: 180, total: 48), 13)
        XCTAssertEqual(MacroProgress.filledDots(180, target: 180, total: 48), 48)
        XCTAssertEqual(MacroProgress.filledDots(179.9, target: 180, total: 48), 47)
        XCTAssertEqual(MacroProgress.filledDots(5, target: 0, total: 48), 0)
    }

    func testIsOver() {
        XCTAssertTrue(MacroProgress.isOver(181, target: 180))
        XCTAssertFalse(MacroProgress.isOver(181, target: 0))
    }
}
