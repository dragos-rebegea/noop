import Foundation
import StrandNutrition

/// Photo-based food recognition through the user's own Anthropic key (the Coach provider).
/// Only runs on an explicit user tap; the image is sent once and never stored.
enum FoodVisionService {
    enum Unavailable: LocalizedError {
        case notAnthropic, noKey
        var errorDescription: String? {
            switch self {
            case .notAnthropic: return String(localized: "Photo logging needs the Anthropic provider. Set it up in Coach.")
            case .noKey: return String(localized: "Add your Anthropic API key in Coach to use photo logging.")
            }
        }
    }

    /// Key and model when the configured Coach provider is Anthropic and its key is present.
    static func credentials() throws -> (key: String, model: String) {
        let provider = UserDefaults.standard.string(forKey: "ai.provider").flatMap(AIProvider.init(rawValue:))
        guard provider == .anthropic, AIKeyStore.ownerProvider == AIProvider.anthropic.rawValue else {
            throw Unavailable.notAnthropic
        }
        guard let key = AIKeyStore.read(), !key.isEmpty else { throw Unavailable.noKey }
        let chosen = UserDefaults.standard.string(forKey: "ai.model") ?? AIProvider.anthropic.defaultModel
        // Structured outputs are not supported on Claude 3.x models (still offered in the Coach picker),
        // so fall back to the provider default for photo logging rather than failing every request.
        let model = chosen.hasPrefix("claude-3") ? AIProvider.anthropic.defaultModel : chosen
        return (key, model)
    }

    static var isAvailable: Bool { (try? credentials()) != nil }

    static func analyzeMeal(photo: Data) async throws -> [FoodVisionReply.MealItem] {
        let (key, model) = try credentials()
        guard let jpeg = FoodImage.jpegForUpload(photo) else { throw FoodVisionReply.Failure.malformed }
        let json = try await AnthropicVision.run(key: key, model: model, prompt: FoodVisionReply.mealPrompt,
                                                 jpeg: jpeg, schemaJSON: FoodVisionReply.mealSchemaJSON)
        return try FoodVisionReply.decodeMeal(json)
    }

    static func analyzeDescription(_ text: String) async throws -> [FoodVisionReply.MealItem] {
        let (key, model) = try credentials()
        let json = try await AnthropicVision.run(key: key, model: model,
                                                 prompt: FoodVisionReply.describePrompt(text), jpeg: nil,
                                                 schemaJSON: FoodVisionReply.mealSchemaJSON)
        return try FoodVisionReply.decodeMeal(json)
    }

    static func readLabel(photo: Data) async throws -> FoodVisionReply.Label {
        let (key, model) = try credentials()
        guard let jpeg = FoodImage.jpegForUpload(photo) else { throw FoodVisionReply.Failure.malformed }
        let json = try await AnthropicVision.run(key: key, model: model, prompt: FoodVisionReply.labelPrompt,
                                                 jpeg: jpeg, schemaJSON: FoodVisionReply.labelSchemaJSON)
        return try FoodVisionReply.decodeLabel(json)
    }
}
