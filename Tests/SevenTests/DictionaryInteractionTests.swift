import AppKit
import XCTest
@testable import Seven

private struct InteractionCredentials: CredentialStoring {
    func read(account: String) throws -> String { "" }
    func save(_ value: String, account: String) throws {}
}

private actor InteractionTranslation: OnlineTranslationServing {
    private(set) var queries: [String] = []
    func translate(_ request: OnlineTranslationRequest) async throws -> OnlineTranslationOutput {
        queries.append(request.text)
        return .init(text: "查询结果", dictionaryEntry: nil)
    }
}

private struct InteractionAudio: SpeechAudioFetching {
    func audio(from url: URL) async throws -> Data { throw SpeechAudioError.transport }
}

@MainActor private final class InteractionVoice: SystemSpeechBackend {
    var onEnd: ((SpeechPlaybackEnd) -> Void)?
    var calls: [(String, String?)] = []
    var stops = 0
    func speak(_ text: String, languageIdentifier: String?, rate: SpeechRate) { calls.append((text, languageIdentifier)) }
    func pause() -> Bool { true }
    func resume() -> Bool { true }
    func stop() { stops += 1 }
}

@MainActor final class DictionaryInteractionTests: XCTestCase {
    private func makeModel(voice: InteractionVoice? = nil, service: InteractionTranslation = InteractionTranslation()) throws -> TranslationModel {
        let defaults = try XCTUnwrap(isolatedDefaults())
        let settings = SettingsStore(defaults: defaults)
        settings.speechEngine = .system
        settings.languageDetectionMode = .system
        settings.serviceInstances = [.init(provider: .youdao)]
        let speech = SpeechController(settings: settings, fetcher: InteractionAudio(), systemBackend: voice ?? InteractionVoice(),
                                      systemVoiceLanguages: { ["en-US", "en-GB"] })
        let model = TranslationModel(youdaoService: service, credentials: InteractionCredentials(), settings: settings, speech: speech)
        model.updateInput("tomato")
        return model
    }

    private func result(headword: String = "tomato", american: String = "təˈmeɪtoʊ", british: String = "təˈmɑːtəʊ") -> TranslationServiceResult {
        let entry = DictionaryEntry(headword: headword,
            pronunciations: [.init(label: "美", value: american), .init(label: "英", value: british)],
            blocks: [.init(id: 0, text: "n. 番茄")], englishDefinitions: ["a red fruit"],
            forms: [.init(id: 0, label: "复数", value: "tomatoes")], labels: ["CET4", "考研"],
            phrases: [.init(id: 0, title: "tomato soup", meanings: ["番茄汤"])],
            examples: [.init(id: 0, source: "I like tomatoes.", translation: "我喜欢番茄。")], rawText: "fixture")
        return .init(id: .youdao, title: "有道", subtitle: "", isTranslation: true, phase: .success,
                     text: "番茄", dictionaryEntry: entry, errorMessage: nil)
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
    private func text(in view: NSView) throws -> NSTextView { try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextView }.first) }
    private func buttons(in view: NSView) -> [NSButton] { descendants(view).compactMap { $0 as? NSButton } }
    private func apply(_ card: AppKitServiceCardView, _ result: TranslationServiceResult) {
        card.apply(result, hasCurrentResult: true, suppressBody: false, animated: false)
    }

    func testYoudaoPronunciationsRespectDisabledPreferenceOnNewResult() throws {
        let model = try makeModel()
        model.youdaoShowsPronunciations = false
        let body = AppKitServiceBodyView(model: model)
        body.apply(result())
        let rendered = try text(in: body).string.replacingOccurrences(of: "\t", with: " ")
        XCTAssertFalse(rendered.contains("təˈmeɪtoʊ"))
        XCTAssertFalse(rendered.contains("təˈmɑːtəʊ"))
        XCTAssertTrue(rendered.contains("n. 番茄"))
    }

    func testYoudaoExamLabelsRespectDisabledDefinitionsOnNewResult() throws {
        let model = try makeModel()
        model.youdaoShowsDefinitions = false
        let body = AppKitServiceBodyView(model: model)
        body.apply(result())
        let rendered = try text(in: body).string.replacingOccurrences(of: "\t", with: " ")
        for hidden in ["CET4", "考研", "n. 番茄", "tomatoes"] { XCTAssertFalse(rendered.contains(hidden), hidden) }
        XCTAssertTrue(rendered.contains("təˈmeɪtoʊ"))
    }

    func testVisibleDictionaryCardRefreshesAllContentPreferencesWithoutNewResult() throws {
        let model = try makeModel(), result = result()
        let card = AppKitServiceCardView(model: model, provider: .youdao)
        apply(card, result)
        XCTAssertFalse(try text(in: card).string.contains("tomato soup"))
        model.youdaoShowsPronunciations = false
        model.youdaoShowsDefinitions = false
        model.youdaoShowsPhrases = true
        model.youdaoShowsExamples = true
        apply(card, result)
        let rendered = try text(in: card).string
        XCTAssertFalse(rendered.contains("təˈmeɪtoʊ"))
        XCTAssertFalse(rendered.contains("CET4"))
        XCTAssertTrue(rendered.contains("tomato soup"))
        XCTAssertTrue(rendered.contains("I like tomatoes."))
        XCTAssertFalse(rendered.contains("a red fruit"))
    }

    func testDictionaryTermsQueryAgainThroughNativeTextClick() async throws {
        let service = InteractionTranslation(), model = try makeModel(service: service)
        model.youdaoShowsPhrases = true
        let body = AppKitServiceBodyView(model: model); body.apply(result())
        let view = try text(in: body), storage = try XCTUnwrap(view.textStorage)
        for term in ["tomatoes", "tomato soup"] {
            let range = NSRange(try XCTUnwrap(view.string.range(of: term)), in: view.string)
            let link = try XCTUnwrap(storage.attribute(.link, at: range.location, effectiveRange: nil))
            XCTAssertEqual(storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor, ThemePalette.system.link)
            view.clicked(onLink: link, at: range.location)
            for _ in 0..<100 {
                if await service.queries.last == term { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let queried = await service.queries
            XCTAssertEqual(queried.last, term); XCTAssertEqual(model.input, term)
        }
        model.cancel()
    }

    func testYoudaoPronunciationButtonsUseHeadwordExplicitAccentsAndIndependentPlayback() throws {
        let voice = InteractionVoice(), model = try makeModel(voice: voice)
        let card = AppKitServiceCardView(model: model, provider: .youdao), result = result()
        apply(card, result)
        let us = try XCTUnwrap(buttons(in: card).first { $0.action == NSSelectorFromString("speakAmerican") })
        let uk = try XCTUnwrap(buttons(in: card).first { $0.action == NSSelectorFromString("speakBritish") })
        us.performClick(nil)
        XCTAssertEqual(model.speech.activeContent, .dictionaryUS)
        XCTAssertEqual(voice.calls.last?.0, "tomato")
        XCTAssertEqual(voice.calls.last?.1, "en-US")
        XCTAssertEqual(model.speech.appearance(for: .dictionaryUS), .playingShort)
        XCTAssertEqual(model.speech.appearance(for: .dictionaryUK), .idle)
        uk.performClick(nil)
        XCTAssertEqual(model.speech.activeContent, .dictionaryUK)
        XCTAssertEqual(voice.calls.last?.0, "tomato")
        XCTAssertEqual(voice.calls.last?.1, "en-GB")
        XCTAssertEqual(model.speech.appearance(for: .dictionaryUS), .idle)
        XCTAssertEqual(model.speech.appearance(for: .dictionaryUK), .playingShort)
        model.youdaoShowsPronunciations = false
        apply(card, result)
        XCTAssertEqual(model.speech.state, .idle, "隐藏发音入口时停止对应朗读")
    }

    func testCollapsingDictionaryCardStopsItsPronunciation() throws {
        let model = try makeModel(), result = result()
        let card = AppKitServiceCardView(model: model, provider: .youdao)
        apply(card, result)
        try XCTUnwrap(buttons(in: card).first { $0.action == NSSelectorFromString("speakBritish") }).performClick(nil)
        XCTAssertTrue(model.speech.isActive(.dictionaryUK))
        model.setServiceExpanded(.youdao, expanded: false)
        apply(card, result)
        XCTAssertEqual(model.speech.state, .idle)
    }

    func testDictionaryTextHasNoExternalLinkDispatch() throws {
        let model = try makeModel(), body = AppKitServiceBodyView(model: model)
        body.apply(result()); let view = try text(in: body)
        XCTAssertEqual(view.delegate?.textView?(view, clickedOnLink: "https://example.invalid", at: 0), true)
        XCTAssertEqual(model.input, "tomato"); XCTAssertFalse(model.isLoading)
    }

    func testYoudaoPreferencesDoNotHideOfflineDictionaryContents() throws {
        let model = try makeModel()
        model.youdaoShowsPronunciations = false
        model.youdaoShowsDefinitions = false
        let source = result()
        let offline = TranslationServiceResult(id: .ecdict, title: "英汉词典", subtitle: "", isTranslation: false,
            phase: .success, text: "番茄", dictionaryEntry: source.dictionaryEntry, errorMessage: nil)
        let body = AppKitServiceBodyView(model: model)
        body.apply(offline)
        let rendered = try text(in: body).string.replacingOccurrences(of: "\t", with: " ")
        XCTAssertTrue(rendered.contains("təˈmeɪtoʊ"))
        XCTAssertTrue(rendered.contains("CET4"))
        XCTAssertTrue(rendered.contains("n. 番茄"))
    }

    func testDictionarySelectionCopyDoesNotContainControlPlaceholders() throws {
        _ = NSApplication.shared
        let body = AppKitServiceBodyView(model: try makeModel())
        body.apply(result())
        let frame = CGRect(x: 0, y: 0, width: 304, height: body.measuredHeight(for: 304))
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = body
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        body.layoutSubtreeIfNeeded()
        let view = try text(in: body)
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        XCTAssertGreaterThan(view.selectedRange().length, 0)
        let pasteboard = NSPasteboard(name: .init("DictionaryLayout-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let plainType = try XCTUnwrap(view.writablePasteboardTypes.first { $0.rawValue == "NSStringPboardType" })
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: [plainType]))
        let copied = try XCTUnwrap(pasteboard.string(forType: plainType))
        XCTAssertFalse(copied.contains("\u{FFFC}"))
        XCTAssertTrue(copied.contains("təˈmeɪtoʊ"))
    }

    func testMissingPhoneticsDoNotCreateEmptyRowsOrButtons() throws {
        for (us, uk, count) in [("", "", 0), ("  ", "", 0), ("", "british", 1), ("american", "", 1)] {
            let body = AppKitServiceBodyView(model: try makeModel())
            body.apply(result(american: us, british: uk))
            XCTAssertEqual(buttons(in: body).filter { $0 is SpeechToggleButton }.count, count)
            let rendered = try text(in: body).string
            if us.trimmingCharacters(in: .whitespaces).isEmpty { XCTAssertFalse(rendered.contains("美\t")) }
            if uk.isEmpty { XCTAssertFalse(rendered.contains("英\t")) }
        }
    }
}
