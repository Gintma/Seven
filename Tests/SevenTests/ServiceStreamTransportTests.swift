import Foundation
import XCTest
@testable import Seven

/// 拦截所有请求，只返回内存中的 SSE；不读取凭据，也不接触真实网络。
private final class StreamFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        let fixture = request.url?.host?.components(separatedBy: ".").first ?? ""
        let text: String
        var status = 200
        switch fixture {
        case "autodetect" where request.url?.path.hasSuffix("/responses") == true:
            status = 400; text = #"{"error":{"code":"unsupported_endpoint"}}"#
        case "http-error": status = 400; text = #"{"error":{"code":"unsupported_value","param":"reasoning_effort"}}"#
        case "huge-error": status = 400; text = String(repeating: " ", count: 16384) + #"{"error":{"code":"model_not_found"}}"#
        case "responses":
            text = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"你\"}\n\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"好\"}\n\ndata: {\"type\":\"response.completed\"}\n\n"
        case "anthropic":
            text = "event: content_block_delta\r\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"你好\"}}\r\n\revent: message_stop\rdata: {\"type\":\"message_stop\"}\r\r"
        case "gemini":
            text = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"你好\"}]},\"finishReason\":\"STOP\"}]}\n\n"
        case "multiline":
            text = "data: {\"choices\":\ndata: [{\"delta\":{\"content\":\"你好\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]"
        case "markdown-whitespace":
            text = #"data: {"choices":[{"delta":{"content":"    example\n\n"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
        case "invalid": text = "data: PRIVATE-NOT-JSON\n\n"
        default:
            text = "\u{FEFF}: keepalive\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"你\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"好\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data = Data(text.utf8)
        // 特意在 JSON 和中文 UTF-8 字符中间切分网络分片。
        for start in stride(from: 0, to: data.count, by: 3) {
            client?.urlProtocol(self, didLoad: data.subdata(in: start..<min(start + 3, data.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor StreamUpdates {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

final class ServiceStreamTransportTests: XCTestCase {
    private func service() -> (CompatibleTranslationService, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        return (CompatibleTranslationService(session: session), session)
    }

    func testCustomStreamingKeepsFinalCodeIndentAndLineBreaks() async throws {
        let (service, session) = service()
        defer { session.invalidateAndCancel() }
        let base = input(.openAICompatible, fixture: "markdown-whitespace")
        var configuration = base.configuration
        configuration.mode = .custom
        configuration.prompt = "Explain"
        let request = TranslationRequest(text: base.text, source: base.source, target: base.target,
                                         configuration: configuration, apiKey: base.apiKey)
        let custom = try await service.translateStream(request) { _ in }
        let normal = try await service.translateStream(base) { _ in }
        XCTAssertEqual(custom, "    example\n\n")
        XCTAssertEqual(normal, "example")
    }

    private func input(_ style: ServiceAPIStyle, fixture: String) -> TranslationRequest {
        let endpoint = ServiceEndpoint.requestAddress(base: "https://\(fixture).fixture.invalid/v1", style: style, model: "fixture-model")
        return TranslationRequest(text: "mock input", source: "en", target: "zh-Hans",
                                  configuration: .init(endpoint: endpoint, model: "fixture-model", apiStyle: style), apiKey: "mock-key")
    }

    func testActualAsyncBytesPreservesEventBoundariesForAllFourFormats() async throws {
        for (style, fixture) in [(ServiceAPIStyle.openAICompatible, "chat"), (.openAIResponses, "responses"), (.anthropic, "anthropic"), (.gemini, "gemini")] {
            let (service, session) = service(); defer { session.invalidateAndCancel() }
            let updates = StreamUpdates()
            let result = try await service.translateStream(input(style, fixture: fixture)) { await updates.append($0) }
            XCTAssertEqual(result, "你好")
            let values = await updates.values
            XCTAssertEqual(values.last, "你好")
            if fixture == "chat" || fixture == "responses" {
                XCTAssertEqual(values, ["你", "你好"], "应逐事件显示，不能等整条流结束后拼成一份 JSON")
            }
        }
    }

    func testActualAsyncBytesSupportsMultilineEventAndFinalLineWithoutNewline() async throws {
        let (service, session) = service(); defer { session.invalidateAndCancel() }
        let result = try await service.translateStream(input(.openAICompatible, fixture: "multiline")) { _ in }
        XCTAssertEqual(result, "你好")
    }

    func testMalformedStreamReturnsReadableErrorInsteadOfFoundationJSONError() async throws {
        let (service, session) = service(); defer { session.invalidateAndCancel() }
        do {
            _ = try await service.translateStream(input(.openAICompatible, fixture: "invalid")) { _ in }
            XCTFail("损坏的 JSON 不应成功")
        } catch {
            XCTAssertEqual(error as? TranslationError, .malformed)
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
        }
    }

    func testStreamingHTTPErrorUsesSameClassificationAndBoundsBodyRead() async throws {
        for fixture in ["http-error", "huge-error"] {
            let (service, session) = service(); defer { session.invalidateAndCancel() }
            do {
                _ = try await service.translateStream(input(.openAICompatible, fixture: fixture)) { _ in }
                XCTFail("应返回错误")
            } catch {
                XCTAssertEqual(error as? TranslationError, fixture == "http-error"
                    ? .configuration(.key("service.reasoningUnsupported")) : .http(400))
            }
        }
    }

    func testVerificationUsesSameStreamingTransportAndOpenAIFallback() async throws {
        let (service, session) = service(); defer { session.invalidateAndCancel() }
        let tester = CompatibleConfigurationTester(service: service)
        for (style, fixture) in [(ServiceAPIStyle.openAICompatible, "chat"), (.openAIResponses, "responses"), (.anthropic, "anthropic"), (.gemini, "gemini")] {
            _ = try await tester.test(configuration: input(style, fixture: fixture).configuration, apiKey: "mock-key")
        }
        var item = ServiceInstance(provider: .openAI)
        item.baseAddress = "https://autodetect.fixture.invalid/v1"
        let detected = try await tester.test(configuration: item.configuration, apiKey: "mock-key")
        XCTAssertEqual(detected.apiStyle, .openAICompatible)
        do {
            _ = try await tester.test(configuration: input(.openAICompatible, fixture: "invalid").configuration, apiKey: "mock-key")
            XCTFail("验证也必须拒绝损坏的流")
        } catch { XCTAssertEqual(error as? TranslationError, .malformed) }
    }

    func testLineDecoderPreservesBlankLinesCRLFAndUTF8AcrossByteBoundaries() throws {
        var decoder = ServiceStreamLineDecoder(), lines: [String] = []
        for byte in Data("\u{FEFF}你好\r\n\r\nnext\r\rlast".utf8) {
            if let line = try decoder.byte(byte) { lines.append(line) }
        }
        if let last = try decoder.finish() { lines.append(last) }
        XCTAssertEqual(lines, ["你好", "", "next", "", "last"])
        var invalid = ServiceStreamLineDecoder()
        _ = try invalid.byte(0xFF)
        XCTAssertThrowsError(try invalid.finish()) { XCTAssertEqual($0 as? TranslationError, .malformed) }
    }
}
