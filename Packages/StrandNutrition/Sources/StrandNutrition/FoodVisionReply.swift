import Foundation

/// The two structured-output contracts for photo logging, their prompts and their decoders.
/// The app sends the schema as `output_config.format`; these decoders accept only that shape.
public enum FoodVisionReply {
    public enum Confidence: String, Codable, Sendable { case low, medium, high }

    public struct MealItem: Equatable, Sendable {
        public init(name: String, grams: Double, per100g: MacroPer100g, confidence: Confidence) {
            self.name = name; self.grams = grams; self.per100g = per100g; self.confidence = confidence
        }
        public var name: String
        public var grams: Double
        public var per100g: MacroPer100g
        public var confidence: Confidence
    }

    public struct Label: Equatable, Sendable {
        public var name: String
        public var per100g: MacroPer100g
        public var servingGrams: Double?
    }

    public enum Failure: Error, Equatable { case malformed, nothingRecognised }

    public static let mealPrompt = """
    Identify each distinct food or drink in this photo. For each, estimate the eaten portion in grams \
    and give typical energy and macronutrients per 100 g. Use common names. If the photo contains no \
    food, return an empty items list.
    """

    public static func describePrompt(_ description: String) -> String {
        """
        The user describes what they ate: "\(description)". List each distinct food or drink with an \
        estimated eaten portion in grams and typical energy and macronutrients per 100 g. If the text \
        describes no food, return an empty items list.
        """
    }

    public static let labelPrompt = """
    Read the nutrition facts table in this photo. Return the product name if visible (otherwise a short \
    description), energy in kcal and protein, carbohydrate and fat in grams, all per 100 g. If the table \
    only gives per-serving values, convert them to per 100 g using the stated serving size. Return the \
    serving size in grams if stated, otherwise null.
    """

    public static let mealSchemaJSON = """
    {"type":"object","additionalProperties":false,"required":["items"],"properties":{"items":{"type":"array",\
    "items":{"type":"object","additionalProperties":false,\
    "required":["name","grams","kcal100","protein100","carbs100","fat100","confidence"],\
    "properties":{"name":{"type":"string"},"grams":{"type":"number"},"kcal100":{"type":"number"},\
    "protein100":{"type":"number"},"carbs100":{"type":"number"},"fat100":{"type":"number"},\
    "confidence":{"type":"string","enum":["low","medium","high"]}}}}}}
    """

    public static let labelSchemaJSON = """
    {"type":"object","additionalProperties":false,\
    "required":["name","kcal100","protein100","carbs100","fat100","servingGrams"],\
    "properties":{"name":{"type":"string"},"kcal100":{"type":"number"},"protein100":{"type":"number"},\
    "carbs100":{"type":"number"},"fat100":{"type":"number"},"servingGrams":{"type":["number","null"]}}}
    """

    private struct WireItem: Decodable {
        let name: String, grams: Double, kcal100: Double, protein100: Double
        let carbs100: Double, fat100: Double, confidence: Confidence
    }
    private struct WireMeal: Decodable { let items: [WireItem] }
    private struct WireLabel: Decodable {
        let name: String, kcal100: Double, protein100: Double, carbs100: Double, fat100: Double
        let servingGrams: Double?
    }

    public static func decodeMeal(_ data: Data) throws -> [MealItem] {
        guard let wire = try? JSONDecoder().decode(WireMeal.self, from: data) else { throw Failure.malformed }
        let items = wire.items.filter { $0.grams > 0 }.map {
            MealItem(name: $0.name, grams: $0.grams,
                     per100g: MacroPer100g(kcal: $0.kcal100, protein: $0.protein100,
                                           carbs: $0.carbs100, fat: $0.fat100),
                     confidence: $0.confidence)
        }
        guard !items.isEmpty else { throw Failure.nothingRecognised }
        return items
    }

    public static func decodeLabel(_ data: Data) throws -> Label {
        guard let w = try? JSONDecoder().decode(WireLabel.self, from: data) else { throw Failure.malformed }
        return Label(name: w.name,
                     per100g: MacroPer100g(kcal: w.kcal100, protein: w.protein100, carbs: w.carbs100, fat: w.fat100),
                     servingGrams: w.servingGrams.flatMap { $0 > 0 ? $0 : nil })
    }
}
