import Foundation
import XCTest
@testable import Seven

final class OnlineTranslationServiceTests: XCTestCase {
    private let input = OnlineTranslationRequest(
        text: "Hello world",
        source: "auto",
        target: "zh-Hans"
    )

    func testGoogleRequestUsesGTXAndMappedLanguages() throws {
        let request = try GoogleTranslationService.makeRequest(input)
        let body = try XCTUnwrap(request.httpBody)
        let form = try formValues(body)

        XCTAssertEqual(request.url, GoogleTranslationService.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(form["client"], "gtx")
        XCTAssertEqual(form["sl"], "auto")
        XCTAssertEqual(form["tl"], "zh-CN")
        XCTAssertEqual(form["q"], "Hello world")
    }

    func testGoogleResponseCombinesSentenceSegments() throws {
        let data = Data(#"{"src":"en","sentences":[{"trans":"你好"},{"trans":"世界"}]}"#.utf8)
        let response = HTTPURLResponse(
            url: GoogleTranslationService.endpoint,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        XCTAssertEqual(try GoogleTranslationService.parse(data, response: response), "你好世界")
    }

    func testYoudaoSignatureMatchesWebProtocol() {
        XCTAssertEqual(
            YoudaoTranslationService.signature(timestamp: "1700000000000", key: "secret"),
            "9f3f187482ad186ad1f97146e24b9819"
        )
    }

    func testYoudaoTranslationRequestMapsLanguagesAndCarriesSignature() throws {
        let key = YoudaoTranslationService.KeyMaterial(
            secretKey: "secret",
            aesKey: "aes-key",
            aesIv: "aes-iv"
        )
        let request = try YoudaoTranslationService.makeTranslationRequest(
            input,
            key: key,
            timestamp: "1700000000000",
            cookie: "OUTFOX_SEARCH_USER_ID=123456789@10.0.0.1;"
        )
        let form = try formValues(XCTUnwrap(request.httpBody))

        XCTAssertEqual(request.url, YoudaoTranslationService.translationEndpoint)
        XCTAssertEqual(form["from"], "auto")
        XCTAssertEqual(form["to"], "zh-CHS")
        XCTAssertEqual(form["i"], "Hello world")
        XCTAssertEqual(form["keyid"], "webfanyi")
        XCTAssertEqual(form["sign"], "9f3f187482ad186ad1f97146e24b9819")
    }

    func testYoudaoDecryptsAndParsesURLSafePayload() throws {
        let encrypted = Data(
            "rqMpVuMvrQZnQkojURQo8etjVO8mngy79ndP5DZyH877awRU62pCiw5gC_zLAtY5X4EFAKTWCq0gZvrlbpmO4XNIjTZlwGTQX52YBL5QkJ8DpgDCrUkEbMoZC2X2xhsn".utf8
        )
        let decrypted = try YoudaoTranslationService.decrypt(
            encrypted,
            aesKey: "test-aes-key",
            aesIV: "test-aes-iv"
        )

        XCTAssertEqual(try YoudaoTranslationService.parseTranslation(decrypted), "你好")
    }

    func testYoudaoParsesStructuredDictionaryEntry() throws {
        let data = Data(#"""
        {
            "ec": {
                "exam_type": ["CET4", "考研"],
                "word": {
                    "return-phrase": "refine",
                    "ukphone": "rɪˈfaɪn",
                    "usphone": "rɪˈfaɪn",
                    "trs": [{"pos": "v.", "tran": "改进，改善"}],
                    "wfs": [{"wf": {"name": "现在分词", "value": "refining"}}]
                }
            },
            "web_trans": {
                "web-translation": [
                    {"key": "refine on", "trans": [{"value": "改进"}]}
                ]
            },
            "ee": {
                "word": {
                    "trs": [
                        {"pos": "verb", "tr": [{"tran": "improve by making small changes"}]}
                    ]
                }
            },
            "blng_sents_part": {
                "sentence-pair": [
                    {"sentence": "We refined the design.", "sentence-translation": "我们改进了设计。"}
                ]
            }
        }
        """#.utf8)
        let response = HTTPURLResponse(
            url: YoudaoTranslationService.dictionaryEndpoint,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        let entry = try XCTUnwrap(YoudaoTranslationService.parseDictionary(
            data,
            response: response,
            fallbackHeadword: "refine"
        ))

        XCTAssertEqual(entry.headword, "refine")
        XCTAssertEqual(entry.pronunciations, [
            .init(label: "美", value: "rɪˈfaɪn"),
            .init(label: "英", value: "rɪˈfaɪn")
        ])
        XCTAssertEqual(entry.blocks.first?.text, "v.  改进，改善")
        XCTAssertEqual(entry.forms.first?.value, "refining")
        XCTAssertEqual(entry.labels, ["CET4", "考研"])
        XCTAssertEqual(entry.phrases, [
            .init(id: 0, title: "refine on", meanings: ["改进"])
        ])
        XCTAssertEqual(entry.englishDefinitions, ["verb  improve by making small changes"])
        XCTAssertEqual(entry.examples, [
            .init(id: 0, source: "We refined the design.", translation: "我们改进了设计。")
        ])
    }

    func testLiveGoogleTranslation() async throws {
        guard ProcessInfo.processInfo.environment["SEVEN_LIVE_TRANSLATION_TESTS"] == "1" else {
            throw XCTSkip("Set SEVEN_LIVE_TRANSLATION_TESTS=1 to run online service checks.")
        }
        let translated = try await GoogleTranslationService().translate(input)
        XCTAssertTrue(translated.text.contains("你好"))
    }

    func testLiveYoudaoTranslation() async throws {
        guard ProcessInfo.processInfo.environment["SEVEN_LIVE_TRANSLATION_TESTS"] == "1" else {
            throw XCTSkip("Set SEVEN_LIVE_TRANSLATION_TESTS=1 to run online service checks.")
        }
        let translated = try await YoudaoTranslationService().translate(.init(
            text: "create",
            source: "auto",
            target: "zh-Hans"
        ))
        XCTAssertTrue(translated.text.contains("创建"))
        let entry = try XCTUnwrap(translated.dictionaryEntry)
        XCTAssertEqual(entry.pronunciations.map(\.label), ["美", "英"])
        XCTAssertTrue(entry.labels.contains("CET4"))
        XCTAssertTrue(entry.phrases.contains { $0.title.localizedCaseInsensitiveContains("create") })
    }

    func testYoudaoTranslationDoesNotDoubleParagraphLineBreaks() throws {
        let data = Data(#"{"code":0,"translateResult":[[{"tgt":"Hello!\n"}],[{"tgt":"Where are you?\n"}],[{"tgt":"I'm here."}]]}"#.utf8)
        XCTAssertEqual(try YoudaoTranslationService.parseTranslation(data), "Hello!\nWhere are you?\nI'm here.")
    }

    func testYoudaoTranslationPreservesLeadingBreaksAndCRLF() throws {
        let data = Data(#"{"code":0,"translateResult":[[{"tgt":"Hello!"}],[{"tgt":"\r\nWhere are you?"}],[{"tgt":"\nI'm here."}]]}"#.utf8)
        XCTAssertEqual(try YoudaoTranslationService.parseTranslation(data), "Hello!\r\nWhere are you?\nI'm here.")
    }

    func testYoudaoTranslationPreservesIntentionalBlankLines() throws {
        let data = Data(#"{"code":0,"translateResult":[[{"tgt":"Hello!\n\n"}],[{"tgt":"Where are you?"}],[{"tgt":"\n\nI'm here."}]]}"#.utf8)
        XCTAssertEqual(try YoudaoTranslationService.parseTranslation(data), "Hello!\n\nWhere are you?\n\nI'm here.")
    }

    func testYoudaoTranslationCombinesSegmentsAndSeparatesUnmarkedParagraphs() throws {
        let data = Data(#"{"code":0,"translateResult":[[{"tgt":"Hello! "},{"tgt":"How are you?"}],[{"tgt":"I'm here."}]]}"#.utf8)
        XCTAssertEqual(try YoudaoTranslationService.parseTranslation(data), "Hello! How are you?\nI'm here.")
    }

    func testYoudaoTranslationPreservesEmptyUnmarkedParagraph() throws {
        let data = Data(#"{"code":0,"translateResult":[[{"tgt":"Hello!"}],[],[{"tgt":"I'm here."}]]}"#.utf8)
        XCTAssertEqual(try YoudaoTranslationService.parseTranslation(data), "Hello!\n\nI'm here.")
    }

    func testYoudaoTranslationRejectsEmptyParagraphs() {
        for payload in [#"{"code":0}"#, #"{"code":0,"translateResult":[[],[{"tgt":" \n"}]]}"#] {
            XCTAssertThrowsError(try YoudaoTranslationService.parseTranslation(Data(payload.utf8))) { error in
                XCTAssertEqual(error as? TranslationError, .empty)
            }
        }
    }

    func testYoudaoErrorCode40MeansUnsupportedLanguage() {
        let data = Data(#"{"code":40}"#.utf8)
        XCTAssertThrowsError(try YoudaoTranslationService.parseTranslation(data)) { error in
            XCTAssertEqual(error as? TranslationError, .unsupportedLanguage(.key("youdaoTranslateDoesNotSupportTheLanguage")))
        }
        XCTAssertThrowsError(try YoudaoTranslationService.parseTranslation(Data(#"{"code":50}"#.utf8))) { error in
            XCTAssertEqual(error as? TranslationError, .transport(.key("youdao.unavailable", .text("50"))))
        }
    }

    /// 逐一核对语言目录里每种语言的 Google、有道代码能否真正翻译。代码为 nil 的语言跳过。
    func testLiveEveryCatalogLanguage() async throws {
        guard ProcessInfo.processInfo.environment["SEVEN_LIVE_TRANSLATION_TESTS"] == "1" else {
            throw XCTSkip("Set SEVEN_LIVE_TRANSLATION_TESTS=1 to run online service checks.")
        }
        let services: [(String, OnlineTranslationServing, (Language) -> String?)] = [
            ("Google", GoogleTranslationService(), { $0.googleCode }),
            ("有道", YoudaoTranslationService(), { $0.youdaoCode })
        ]
        for (name, service, code) in services {
            for language in LanguageCatalog.all where code(language) != nil {
                let chineseOnly = name == "有道" && ServiceLanguageSupport.youdaoChineseOnly.contains(language.code)
                let source = language.code == "en" || chineseOnly ? "zh-Hans" : "en"
                let text = source == "en" ? "Good morning, how are you today?" : "早上好，你今天好吗？"
                do {
                    let output = try await service.translate(.init(text: text, source: source, target: language.code))
                    XCTAssertFalse(output.text.isEmpty, "\(name) \(language.code) 返回空译文")
                    XCTAssertNotEqual(output.text, text, "\(name) \(language.code) 未翻译")
                } catch {
                    XCTFail("\(name) \(language.code)：\(error)")
                }
            }
        }
    }

    private func formValues(_ data: Data) throws -> [String: String] {
        let query = try XCTUnwrap(String(data: data, encoding: .utf8))
        var components = URLComponents()
        components.percentEncodedQuery = query
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}
