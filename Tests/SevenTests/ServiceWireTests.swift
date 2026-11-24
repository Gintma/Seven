import Foundation
import XCTest
@testable import Seven

final class ServiceWireTests: XCTestCase {
    private func input(_ style: ServiceAPIStyle) -> TranslationRequest {
        .init(text:"Hello",source:"en",target:"zh-Hans",configuration:.init(endpoint:ServiceEndpoint.requestAddress(base:"https://api.example.com/v1",style:style,model:"test-model"),model:"test-model",apiStyle:style),apiKey:"mock-key")
    }
    private func decode(_ style:ServiceAPIStyle, _ events:[String]) throws -> (String,Bool) {
        var decoder=ServiceStreamDecoder(style:style),text=""
        for event in events {
            text += try decoder.line("event: ignored")
            text += try decoder.line("data: "+event)
            text += try decoder.line("")
        }
        text += try decoder.flush()
        return (text,decoder.completed)
    }
    func testRequestsUseCorrectHeadersAndBodiesForAllFourFormats() throws {
        for style in ServiceAPIStyle.allCases {
            let request=try CompatibleTranslationService.makeURLRequest(input(style))
            let body=try XCTUnwrap(JSONSerialization.jsonObject(with:try XCTUnwrap(request.httpBody)) as? [String:Any])
            XCTAssertEqual(request.httpMethod,"POST");XCTAssertEqual(request.value(forHTTPHeaderField:"Accept"),"text/event-stream")
            XCTAssertFalse(request.url!.absoluteString.contains("mock-key"))
            XCTAssertNil(body["temperature"]); XCTAssertNil(body["max_output_tokens"]); XCTAssertNil(body["max_completion_tokens"])
            if style == .anthropic { XCTAssertEqual(body["max_tokens"] as? Int, 8192) }
            else { XCTAssertNil(body["max_tokens"]) }
            let generation = body["generationConfig"] as? [String: Any]
            XCTAssertNil(generation?["temperature"]); XCTAssertNil(generation?["maxOutputTokens"])
            switch style {
            case .openAICompatible:
                XCTAssertEqual(request.url?.path,"/v1/chat/completions");XCTAssertNotNil(body["messages"])
                XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer mock-key")
            case .openAIResponses:
                XCTAssertEqual(request.url?.path,"/v1/responses");XCTAssertEqual(body["input"] as? String,"Hello");XCTAssertEqual(body["store"] as? Bool,false)
            case .anthropic:
                XCTAssertEqual(request.url?.path,"/v1/messages");XCTAssertEqual(request.value(forHTTPHeaderField:"x-api-key"),"mock-key")
                XCTAssertNotNil(body["system"]);XCTAssertEqual(body["stream"] as? Bool,true);XCTAssertNil(request.value(forHTTPHeaderField:"Authorization"))
            case .gemini:
                XCTAssertEqual(request.url?.path,"/v1/models/test-model:streamGenerateContent");XCTAssertEqual(request.url?.query,"alt=sse")
                XCTAssertEqual(request.value(forHTTPHeaderField:"x-goog-api-key"),"mock-key");XCTAssertNotNil(body["systemInstruction"]);XCTAssertNotNil(body["contents"])
            }
        }
    }
    func testAnthropicStreamingOnlyAccumulatesTextAndRequiresMessageStop() throws {
        let events=[
            #"{"type":"message_start","message":{}}"#,
            #"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hidden"}}"#,
            #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"你"}}"#,
            #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"好"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"{"type":"message_stop"}"#]
        let result=try decode(.anthropic,events);XCTAssertEqual(result.0,"你好");XCTAssertTrue(result.1)
        XCTAssertFalse(try decode(.anthropic,Array(events.dropLast())).1)
    }
    func testResponsesStreamingDoesNotAppendFinalSnapshotAgain() throws {
        let result=try decode(.openAIResponses,[
            #"{"error":null,"type":"response.output_text.delta","delta":"你好"}"#,
            #"{"type":"response.output_text.done","text":"你好"}"#,
            #"{"type":"response.completed","response":{"status":"completed"}}"#])
        XCTAssertEqual(result.0,"你好");XCTAssertTrue(result.1)
    }
    func testGeminiStreamingSupportsStopAndIgnoresMetadata() throws {
        let result=try decode(.gemini,[
            #"{"candidates":[{"content":{"parts":[{"thought":true,"text":"hidden"},{"text":"你"}]}}]}"#,
            #"{"candidates":[{"content":{"parts":[{"text":"好"}]},"finishReason":"STOP"}],"usageMetadata":{}}"#])
        XCTAssertEqual(result.0,"你好");XCTAssertTrue(result.1)
    }
    func testTruncationAndErrorFramesFailForEveryFormat() throws {
        for (style,event) in [
            (ServiceAPIStyle.openAICompatible,#"{"choices":[{"delta":{"content":"half"},"finish_reason":"length"}]}"#),
            (.anthropic,#"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#),
            (.openAIResponses,#"{"type":"response.incomplete"}"#),
            (.gemini,#"{"candidates":[{"finishReason":"MAX_TOKENS"}]}"#)
        ] { XCTAssertThrowsError(try decode(style,[event])) { XCTAssertEqual($0 as? TranslationError,.incomplete) } }
        for style in ServiceAPIStyle.allCases {
            XCTAssertThrowsError(try decode(style,[#"{"error":{"message":"raw text mock-key"}}"#])) {
                XCTAssertFalse($0.localizedDescription.contains("mock-key"));XCTAssertFalse($0.localizedDescription.contains("raw text"))
            }
        }
    }
    func testSSEMultilineCommentsAndFinalEventWithoutBlankLine() throws {
        var d=ServiceStreamDecoder(style:.openAIResponses)
        XCTAssertEqual(try d.line(": keep-alive"),"")
        XCTAssertEqual(try d.line("data: {\"type\":\"response.output_text.delta\","),"")
        XCTAssertEqual(try d.line("data: \"delta\":\"你好\"}"),"")
        XCTAssertEqual(try d.flush(),"你好");XCTAssertFalse(d.completed)
    }
    func testHTTPFailuresAndCredentialNewlinesAreRejected() throws {
        for style in ServiceAPIStyle.allCases {
            var i=input(style).configuration
            i.endpoint="https://user:secret@api.example.com/v1/messages"
            XCTAssertThrowsError(try i.validatedURL())
            let request=input(style)
            XCTAssertThrowsError(try CompatibleTranslationService.makeURLRequest(.init(text:request.text,source:request.source,target:request.target,configuration:request.configuration,apiKey:"bad\nkey")))
        }
    }
}
