import XCTest
@testable import StrandNutrition

final class OpenFoodFactsTests: XCTestCase {
    private func decode(_ json: String) throws -> OpenFoodFacts.Result {
        try OpenFoodFacts.decode(Data(json.utf8))
    }

    func testCompleteProduct() throws {
        let r = try decode("""
        {"code":"5941234567890","status":1,"product":{"product_name":"Fulgi de ovaz","brands":"Acme",
         "serving_quantity":"40","nutriments":{"energy-kcal_100g":372,"proteins_100g":13.5,
         "carbohydrates_100g":58.7,"fat_100g":7}}}
        """)
        guard case .found(let p) = r else { return XCTFail("expected found") }
        XCTAssertEqual(p.name, "Fulgi de ovaz")
        XCTAssertEqual(p.brand, "Acme")
        XCTAssertEqual(p.servingGrams, 40)
        XCTAssertEqual(p.per100g, MacroPer100g(kcal: 372, protein: 13.5, carbs: 58.7, fat: 7))
    }

    func testKilojoulesOnlyConverted() throws {
        let r = try decode("""
        {"status":1,"product":{"product_name":"X","nutriments":{"energy_100g":"1046",
         "proteins_100g":"10","carbohydrates_100g":"40","fat_100g":"2"}}}
        """)
        guard case .found(let p) = r else { return XCTFail("expected found") }
        XCTAssertEqual(p.per100g?.kcal ?? 0, 1046 / 4.184, accuracy: 1e-6)
        XCTAssertNil(p.brand)
        XCTAssertNil(p.servingGrams)
    }

    func testMissingMacrosGivesNilPer100g() throws {
        let r = try decode("""
        {"status":1,"product":{"product_name":"Y","nutriments":{"energy-kcal_100g":100,"fat_100g":1}}}
        """)
        guard case .found(let p) = r else { return XCTFail("expected found") }
        XCTAssertNil(p.per100g)
    }

    func testNotFound() throws {
        XCTAssertEqual(try decode(#"{"code":"1","status":0,"status_verbose":"product not found"}"#), .notFound)
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try decode("<html>"))
    }
}
