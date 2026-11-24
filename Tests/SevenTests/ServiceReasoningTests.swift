import Foundation
import XCTest
@testable import Seven

final class ServiceReasoningTests: XCTestCase {
    private func body(_ item: ServiceInstance) throws -> [String: Any] {
        let request = TranslationRequest(text: "Hello", source: "en", target: "zh-Hans",
                                         configuration: item.configuration, apiKey: "mock-key")
        let wire = try CompatibleTranslationService.makeURLRequest(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(wire.httpBody)) as? [String: Any])
    }

    func testDefaultOmitsAllReasoningParametersForEveryProvider() throws {
        for provider in ServiceProvider.keyProviders {
            var item = ServiceInstance(provider: provider)
            if item.model.isEmpty { item.model = "test-model" }
            if item.baseAddress.isEmpty { item.baseAddress = "https://example.com/v1" }
            let json = try body(item)
            for field in ["reasoning", "reasoning_effort", "thinking", "output_config", "generationConfig"] {
                XCTAssertNil(json[field], "默认不应发送 \(field)：\(provider)")
            }
        }
    }

    func testProviderMappingsWorkInStreamingRequests() throws {
        var item = ServiceInstance(provider: .openAI); item.reasoningEffort = .low
        let responses = try body(item)
        XCTAssertEqual((responses["reasoning"] as? [String: String])?["effort"], "low")
        item.apiStyle = .openAICompatible
        XCTAssertEqual(try body(item)["reasoning_effort"] as? String, "low")

        item = ServiceInstance(provider: .claude); item.reasoningEffort = .medium
        let claude = try body(item)
        XCTAssertEqual((claude["output_config"] as? [String: String])?["effort"], "medium")
        XCTAssertNil(claude["reasoning_effort"])

        item = ServiceInstance(provider: .gemini); item.reasoningEffort = .high
        let gemini = try body(item)
        let generation = try XCTUnwrap(gemini["generationConfig"] as? [String: Any])
        XCTAssertEqual((generation["thinkingConfig"] as? [String: String])?["thinkingLevel"], "HIGH")
        XCTAssertNil(gemini["reasoning_effort"])

        item = ServiceInstance(provider: .deepSeek); item.reasoningEffort = .max
        let deepSeek = try body(item)
        XCTAssertEqual((deepSeek["thinking"] as? [String: String])?["type"], "enabled")
        XCTAssertEqual(deepSeek["reasoning_effort"] as? String, "max")
        item.reasoningEffort = .none as ReasoningEffort
        let disabled = try body(item)
        XCTAssertEqual((disabled["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertNil(disabled["reasoning_effort"])
    }

    func testKnownModelsWorkThroughProxyAndExplicitCustomProtocols() throws {
        var item = ServiceInstance(provider: .openAI); item.reasoningEffort = .high
        item.model = "gpt-6-unknown"; item.baseAddress = "https://proxy.example.com/v1"
        XCTAssertNil(try body(item)["reasoning"])
        item.model = "gpt-6-luna"
        XCTAssertEqual(try body(item)["reasoning"] as? [String: String], ["effort": "high"])
        item.detectedAPIStyle = .openAICompatible
        XCTAssertEqual(try body(item)["reasoning_effort"] as? String, "high")
        item = ServiceInstance(provider: .custom); item.model = "gpt-6-luna"
        item.baseAddress = "https://proxy.example.com/v1"; item.reasoningEffort = .high
        XCTAssertEqual(try body(item)["reasoning_effort"] as? String, "high")
        item.apiStyle = .openAIResponses
        XCTAssertEqual(try body(item)["reasoning"] as? [String: String], ["effort": "high"])
        item.apiStyle = .anthropic
        XCTAssertNil(try body(item)["output_config"], "不匹配的协议不能发送思考参数")
        item.model = "claude-haiku-5-5"
        XCTAssertEqual(try body(item)["output_config"] as? [String: String], ["effort": "high"])
        item.apiStyle = .gemini; item.model = "gemini-3.8-flash"
        XCTAssertNotNil(try body(item)["generationConfig"])
    }

    func testOptionsAreModelSpecificAndInvalidSavedEffortIsNotSent() throws {
        func options(_ provider: ServiceProvider, _ model: String) -> [ReasoningEffort] {
            ServiceReasoning.options(provider: provider, model: model, style: provider.apiStyle)
        }
        XCTAssertTrue(options(.openAI, "gpt-6-luna").contains(.none))
        XCTAssertFalse(options(.openAI, "gpt-6-astra").contains(.none))
        XCTAssertFalse(options(.claude, "claude-sonnet-4-6").contains(.xhigh))
        XCTAssertTrue(options(.claude, "claude-haiku-4-5").isEmpty)
        XCTAssertFalse(options(.gemini, "gemini-3.8-flash").contains(.minimal))
        XCTAssertTrue(options(.gemini, "gemini-3.6-flash").contains(.minimal))
        XCTAssertEqual(options(.deepSeek, "deepseek-flash"), [.none, .low, .high, .max])
        var item = ServiceInstance(provider: .gemini); item.reasoningEffort = .max
        XCTAssertNil(try body(item)["generationConfig"])
    }

    func testLegacyInstancesAndConfigurationsDecodeWithoutNewFields() throws {
        let item = ServiceInstance(provider: .openAI)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        json.removeValue(forKey: "reasoningEffort")
        let old = try JSONDecoder().decode(ServiceInstance.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.reasoningEffort)
        let config = try JSONDecoder().decode(ServiceConfiguration.self, from: Data(#"{"model":"old-model"}"#.utf8))
        XCTAssertNil(config.reasoningEffort); XCTAssertNil(config.reasoningProvider)
    }

    func testEffortIsPersistedPerInstanceAndSurvivesConfigurationRoundTrip() throws {
        var first = ServiceInstance(provider: .openAI), second = ServiceInstance(provider: .openAI)
        first.reasoningEffort = .low; second.reasoningEffort = .high
        let decoded = try JSONDecoder().decode([ServiceInstance].self, from: JSONEncoder().encode([first, second]))
        XCTAssertEqual(decoded.map(\.reasoningEffort), [.low, .high])
        XCTAssertNotEqual(decoded[0].id, decoded[1].id)
        let config = try JSONDecoder().decode(ServiceConfiguration.self, from: JSONEncoder().encode(first.configuration))
        XCTAssertEqual(config.reasoningEffort, .low); XCTAssertEqual(config.reasoningProvider, .openAI)
        second.apply(config)
        XCTAssertEqual(second.reasoningEffort, .low)
        XCTAssertEqual(try body(decoded[1])["reasoning"] as? [String: String], ["effort": "high"])
    }
}
