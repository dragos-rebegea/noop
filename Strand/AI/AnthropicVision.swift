import Foundation

/// One-shot Anthropic Messages call with an image and a JSON-schema structured output, used by
/// food photo and nutrition-label logging. Kept apart from the streaming chat client, which only
/// carries text content.
enum AnthropicVision {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func makeRequest(key: String, model: String, prompt: String, jpeg: Data,
                            schemaJSON: String) throws -> URLRequest {
        let schema = try JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                    ["type": "text", "text": prompt],
                ],
            ]],
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
        ]
        var req = URLRequest(url: AIProvider.anthropic.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// The structured-output JSON text of a successful response.
    static func extractJSON(_ data: Data) throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Unexpected response")
        }
        if (root["stop_reason"] as? String) == "refusal" { throw Failure(message: "The model declined this photo") }
        let blocks = root["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw Failure(message: "Empty response")
        }
        return Data(text.utf8)
    }

    static func run(key: String, model: String, prompt: String, jpeg: Data, schemaJSON: String,
                    session: URLSession = .shared) async throws -> Data {
        let req = try makeRequest(key: key, model: model, prompt: prompt, jpeg: jpeg, schemaJSON: schemaJSON)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw Failure(message: msg ?? "Request failed (HTTP \(status))")
        }
        return try extractJSON(data)
    }
}
