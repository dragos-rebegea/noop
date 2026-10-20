import XCTest
@testable import Strand

final class AnthropicVisionTests: XCTestCase {
    func testRequestShape() throws {
        let req = try AnthropicVision.makeRequest(key: "k", model: "claude-sonnet-5-5", prompt: "P",
                                                  jpeg: Data([1, 2, 3]), schemaJSON: #"{"type":"object"}"#)
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        let content = ((body["messages"] as! [[String: Any]])[0]["content"]) as! [[String: Any]]
        XCTAssertEqual(content[0]["type"] as? String, "image")
        let source = content[0]["source"] as! [String: Any]
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual(content[1]["text"] as? String, "P")
        let format = (body["output_config"] as! [String: Any])["format"] as! [String: Any]
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertNotNil(format["schema"] as? [String: Any])
    }

    func testExtractText() throws {
        let ok = Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"{\"items\":[]}"}]}"#.utf8)
        XCTAssertEqual(try AnthropicVision.extractJSON(ok), Data(#"{"items":[]}"#.utf8))
        let refused = Data(#"{"stop_reason":"refusal","content":[]}"#.utf8)
        XCTAssertThrowsError(try AnthropicVision.extractJSON(refused))
    }
}
