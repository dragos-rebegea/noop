import XCTest
@testable import StrandNutrition

final class FoodVisionReplyTests: XCTestCase {
    func testMealValid() throws {
        let items = try FoodVisionReply.decodeMeal(Data("""
        {"items":[{"name":"Grilled chicken breast","grams":150,"kcal100":165,"protein100":31,
          "carbs100":0,"fat100":3.6,"confidence":"high"},
         {"name":"White rice","grams":200,"kcal100":130,"protein100":2.7,"carbs100":28,
          "fat100":0.3,"confidence":"medium"}]}
        """.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].name, "Grilled chicken breast")
        XCTAssertEqual(items[0].grams, 150)
        XCTAssertEqual(items[0].per100g, MacroPer100g(kcal: 165, protein: 31, carbs: 0, fat: 3.6))
        XCTAssertEqual(items[1].confidence, .medium)
    }

    func testMealEmptyThrowsNothingFound() {
        XCTAssertThrowsError(try FoodVisionReply.decodeMeal(Data(#"{"items":[]}"#.utf8))) {
            XCTAssertEqual($0 as? FoodVisionReply.Failure, .nothingRecognised)
        }
    }

    func testMealMalformedThrows() {
        XCTAssertThrowsError(try FoodVisionReply.decodeMeal(Data(#"{"items":[{"name":"x"}]}"#.utf8))) {
            XCTAssertEqual($0 as? FoodVisionReply.Failure, .malformed)
        }
    }

    func testMealDropsNonPositiveGrams() throws {
        let items = try FoodVisionReply.decodeMeal(Data("""
        {"items":[{"name":"a","grams":0,"kcal100":1,"protein100":0,"carbs100":0,"fat100":0,"confidence":"low"},
                  {"name":"b","grams":10,"kcal100":1,"protein100":0,"carbs100":0,"fat100":0,"confidence":"low"}]}
        """.utf8))
        XCTAssertEqual(items.map(\.name), ["b"])
    }

    func testLabelValid() throws {
        let l = try FoodVisionReply.decodeLabel(Data("""
        {"name":"Greek yogurt 2%","kcal100":73,"protein100":10,"carbs100":3.6,"fat100":2,"servingGrams":null}
        """.utf8))
        XCTAssertEqual(l.name, "Greek yogurt 2%")
        XCTAssertEqual(l.per100g, MacroPer100g(kcal: 73, protein: 10, carbs: 3.6, fat: 2))
        XCTAssertNil(l.servingGrams)
    }

    func testSchemasAreValidJSON() throws {
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(FoodVisionReply.mealSchemaJSON.utf8)))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(FoodVisionReply.labelSchemaJSON.utf8)))
    }
}
