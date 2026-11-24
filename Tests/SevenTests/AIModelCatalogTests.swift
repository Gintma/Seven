import Foundation
import XCTest
@testable import Seven

final class AIModelCatalogTests: XCTestCase {
    func testModelsURLForEachFormatUsesBaseAddress() throws {
        for (style, endpoint, expected) in [
            (ServiceAPIStyle.openAICompatible, "https://api.example.com/v1/chat/completions", "https://api.example.com/v1/models"),
            (.openAIResponses, "https://api.example.com/v1/responses", "https://api.example.com/v1/models"),
            (.anthropic, "https://api.example.com/v1/messages", "https://api.example.com/v1/models"),
            (.gemini, "https://api.example.com/v1beta/models/example:generateContent", "https://api.example.com/v1beta/models")
        ] {
            XCTAssertEqual(try AIModelCatalogService.modelsURL(for: .init(endpoint: endpoint, model: "example", apiStyle: style)).absoluteString, expected)
        }
    }
    func testOpenAICatalogPreservesModelIDsWithoutFreeAliases() throws {
        let data = Data(#"{"data":[{"id":"glm-5.3"},{"id":"glm-5.3"},{"id":"glm-4.7-flash"}]}"#.utf8)
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string:"https://api.example.com/v1/models")!, statusCode:200,httpVersion:nil,headerFields:nil))
        XCTAssertEqual(try AIModelCatalogService.parse(data,response:response).models,["glm-4.7-flash","glm-5.3"])
    }
    func testModelsCanBeFetchedBeforeChoosingModelOrWritingPrompt() throws {
        let c=ServiceConfiguration(endpoint:"https://api.example.com/v1/responses",model:"",mode:.custom,apiStyle:.openAIResponses)
        XCTAssertEqual(try AIModelCatalogService.modelsURL(for:c).absoluteString,"https://api.example.com/v1/models")
    }
    func testModelListIgnoresTranslationTimeout() throws {
        var config = ServiceConfiguration(endpoint: "https://example.com/v1/messages", model: "", apiStyle: .anthropic)
        config.timeoutSeconds = -1
        XCTAssertEqual(try AIModelCatalogService.modelsURL(for: config).absoluteString, "https://example.com/v1/models")
    }
    func testGeminiCatalogStripsModelPrefix() throws {
        let data = Data(#"{"models":[{"name":"models/gemini-3.8-flash"}]}"#.utf8)
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string:"https://api.example.com/v1beta/models")!,statusCode:200,httpVersion:nil,headerFields:nil))
        XCTAssertEqual(try AIModelCatalogService.parse(data,response:response).models,["gemini-3.8-flash"])
    }
}
