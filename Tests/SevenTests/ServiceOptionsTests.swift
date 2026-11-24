import Foundation
import XCTest
@testable import Seven

private actor VerificationService: TranslationServing {
    enum Reply: Sendable { case json(String, Int), failure(TranslationError), success }
    var replies: [Reply]
    private(set) var requests: [TranslationRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func translateStream(_ request: TranslationRequest, onUpdate: @escaping @Sendable (String) async -> Void) async throws -> String {
        requests.append(request)
        let wire = try CompatibleTranslationService.makeURLRequest(request)
        XCTAssertEqual(wire.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        switch replies.removeFirst() {
        case .success: return "OK"
        case .failure(let error): throw error
        case .json(let text, let status):
            guard (200..<300).contains(status) else { throw ServiceAPIError.response(Data(text.utf8), status: status) }
            var decoder = ServiceStreamDecoder(style: request.configuration.apiStyle)
            _ = try decoder.line("data: " + text)
            let result = try decoder.line("")
            await onUpdate(result)
            return result
        }
    }
}

private actor SuspendedVerificationService: TranslationServing {
    private var pending: CheckedContinuation<String, Error>?
    private(set) var count = 0
    var isWaiting: Bool { pending != nil }
    func translateStream(_ request: TranslationRequest, onUpdate: @escaping @Sendable (String) async -> Void) async throws -> String {
        count += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func reject() { pending?.resume(throwing: TranslationError.endpointUnsupported); pending = nil }
}

final class ServiceOptionsTests: XCTestCase {
    func testRemovedLegacyFieldsAreIgnoredWithoutDroppingService() throws {
        let item = ServiceInstance(provider: .openAI)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        object["streamingEnabled"] = false
        object["temperature"] = "obsolete"
        object["maximumOutputTokens"] = -1
        let defaults = try XCTUnwrap(isolatedDefaults())
        defaults.set(try JSONSerialization.data(withJSONObject: [object]), forKey: "serviceInstances.v2")
        let loaded = SettingsStore(defaults: defaults).migrateServiceInstances()
        XCTAssertEqual(loaded, [item])
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded[0])) as? [String: Any])
        for field in ["streamingEnabled", "temperature", "maximumOutputTokens"] { XCTAssertNil(encoded[field]) }
        let oldConfiguration = Data(#"{"streamingEnabled":false,"temperature":"obsolete","maximumOutputTokens":-1,"model":"test"}"#.utf8)
        let config = try JSONDecoder().decode(ServiceConfiguration.self, from: oldConfiguration)
        XCTAssertEqual(config.model, "test")
        let encodedConfig = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        for field in ["streamingEnabled", "temperature", "maximumOutputTokens"] { XCTAssertNil(encodedConfig[field]) }
    }

    func testVerificationSwitchesStandardPathOnlyWhenExplicitlyUnsupported() async throws {
        let service = VerificationService([.json(#"{"error":{"code":"unsupported_endpoint","message":"private text"}}"#, 400),
                                           .json(#"{"choices":[{"delta":{"content":"OK"},"finish_reason":"stop"}]}"#, 200)])
        let item = ServiceInstance(provider: .openAI)
        let result = try await CompatibleConfigurationTester(service: service).test(configuration: item.configuration, apiKey: "mock-key")
        XCTAssertEqual(result.apiStyle, .openAICompatible)
        let requests = await service.requests
        XCTAssertEqual(requests.map(\.configuration.apiStyle), [.openAIResponses, .openAICompatible])
        XCTAssertEqual(requests.map { URL(string: $0.configuration.endpoint)?.path }, ["/v1/responses", "/v1/chat/completions"])
        XCTAssertEqual(Set(requests.map(\.configuration.hostLabel)), ["api.openai.com"])
        XCTAssertTrue(requests.allSatisfy { $0.text == "Connection test" })
    }

    func testVerificationDoesNotSwitchForAuthQuotaModelTimeoutOrMalformedOutput() async throws {
        let failures: [TranslationError] = [.http(401), .http(403), .http(429), .modelUnavailable, .http(500),
                                             .transport("请求超时"), .malformed, .incomplete]
        for failure in failures {
            let service = VerificationService([.failure(failure), .success])
            do {
                _ = try await CompatibleConfigurationTester(service: service).test(configuration: ServiceInstance(provider: .openAI).configuration, apiKey: "mock")
                XCTFail("不应忽略错误")
            } catch { XCTAssertEqual(error as? TranslationError, failure) }
            let count = await service.requests.count
            XCTAssertEqual(count, 1, "不能把 \(failure) 当成路径问题重试")
        }
    }

    func testCustomServiceDoesNotAutoDetectAndFirstSuccessNeedsOnlyOneRequest() async throws {
        var custom = ServiceInstance(provider: .custom); custom.baseAddress = "https://example.com/v1"; custom.model = "test"
        let service = VerificationService([.failure(.endpointUnsupported), .success])
        do {
            _ = try await CompatibleConfigurationTester(service: service).test(configuration: custom.configuration, apiKey: "")
            XCTFail("自定义服务不应切换格式")
        } catch { XCTAssertEqual(error as? TranslationError, .endpointUnsupported) }
        let customCount = await service.requests.count; XCTAssertEqual(customCount, 1)
        let success = VerificationService([.success])
        let result = try await CompatibleConfigurationTester(service: success).test(configuration: ServiceInstance(provider: .openAI).configuration, apiKey: "mock")
        XCTAssertEqual(result.apiStyle, .openAIResponses)
        let count = await success.requests.count; XCTAssertEqual(count, 1)
    }

    func testCancellationStopsBeforeTryingAnotherEndpoint() async throws {
        let service = SuspendedVerificationService()
        let task = Task { try await CompatibleConfigurationTester(service: service).test(configuration: ServiceInstance(provider: .openAI).configuration, apiKey: "mock") }
        for _ in 0..<100 {
            if await service.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await service.isWaiting; XCTAssertTrue(waiting)
        task.cancel(); await service.reject()
        do { _ = try await task.value; XCTFail("取消后不应成功") } catch { XCTAssertTrue(error is CancellationError) }
        let count = await service.count; XCTAssertEqual(count, 1)
    }

    func testErrorsAreClassifiedWithoutLeakingServerText() throws {
        let sentinel = "PRIVATE-KEY-AND-TEXT"
        XCTAssertEqual(ServiceAPIError.response(Data(), status: 404), .endpointUnsupported)
        let model = Data(#"{"error":{"code":"model_not_found","message":"PRIVATE-KEY-AND-TEXT"}}"#.utf8)
        XCTAssertEqual(ServiceAPIError.response(model, status: 404), .modelUnavailable)
        XCTAssertEqual(ServiceAPIError.mapped(["param": "model", "message": "This model is not supported in the v1/responses endpoint"], status: 400), .endpointUnsupported)
        let unknown = ServiceAPIError.response(Data(#"{"error":{"message":"PRIVATE-KEY-AND-TEXT"}}"#.utf8), status: 400)
        XCTAssertFalse(unknown.localizedDescription.contains(sentinel))
        XCTAssertNotEqual(unknown, .endpointUnsupported)
        XCTAssertNotEqual(ServiceAPIError.response(Data(#"{"error":{"message":"unknown failure"}}"#.utf8), status: 404), .endpointUnsupported)
        XCTAssertEqual(ServiceAPIError.response(Data(#"{"code":"model_not_found","message":"PRIVATE-KEY-AND-TEXT"}"#.utf8), status: 404), .modelUnavailable)
        for code in [401, 403, 429] { XCTAssertEqual(ServiceAPIError.response(model, status: code), .http(code)) }
        XCTAssertEqual(ServiceEndpoint.pastedOpenAIStyle("https://proxy.example.com/v1/chat/completions"), .openAICompatible)
        XCTAssertEqual(ServiceEndpoint.pastedOpenAIStyle("https://proxy.example.com/v1/responses"), .openAIResponses)
        XCTAssertNil(ServiceEndpoint.pastedOpenAIStyle("https://proxy.example.com/v1"))
        XCTAssertEqual(ServiceAPIError.mapped(["code": "unsupported_parameter", "param": "reasoning_effort"], status: 400),
                       .configuration(.key("service.reasoningUnsupported")))
    }

    func testLegacyNonstandardOpenAIFormatStillMigratesAsCustom() throws {
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: "LegacyFormat-" + UUID().uuidString))
        let settings = SettingsStore(defaults: defaults)
        settings.configured = true
        settings.configuration = ServiceConfiguration(endpoint: "https://api.openai.com/v1/messages", model: "test", apiStyle: .anthropic)
        let migrated = settings.migrateServiceInstances()
        XCTAssertEqual(migrated.last?.provider, .custom)
        XCTAssertEqual(migrated.last?.apiStyle, .anthropic)
    }
}
