import AppKit
import XCTest
import Combine
@testable import Seven

final class SpeechControllerTests: XCTestCase {
    @MainActor func testSpeechOptionNotificationsExposeNewValues() throws {
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: "SpeechNotify-" + UUID().uuidString))
        let controller = SpeechController(settings: SettingsStore(defaults: defaults))
        var snapshots: [(SpeechRate, SpeechEnglishAccent)] = []
        let subscription = controller.objectWillChange.sink {
            snapshots.append((controller.rate(for: .system), controller.englishAccent(for: .system)))
        }
        defer { subscription.cancel() }
        controller.setRate(.fast, for: .system)
        controller.setEnglishAccent(.uk, for: .system)
        XCTAssertEqual(snapshots.map(\.0), [.fast, .fast], "通知触发求值时必须已经能读到新语速")
        XCTAssertEqual(snapshots.map(\.1), [.us, .uk], "通知触发求值时必须已经能读到新口音")
    }

    func testPlaybackPolicyStartsSwitchesPausesAndResumes() {
        XCTAssertEqual(
            SpeechPlaybackPolicy.decision(
                state: .idle,
                activeContent: nil,
                requestedContent: .source
            ),
            .start
        )
        XCTAssertEqual(
            SpeechPlaybackPolicy.decision(
                state: .speaking,
                activeContent: .source,
                requestedContent: .source
            ),
            .pause
        )
        XCTAssertEqual(
            SpeechPlaybackPolicy.decision(
                state: .paused,
                activeContent: .source,
                requestedContent: .source
            ),
            .resume
        )
        XCTAssertEqual(
            SpeechPlaybackPolicy.decision(
                state: .speaking,
                activeContent: .source,
                requestedContent: .translation(.youdao)
            ),
            .start
        )
    }

    func testSpeechLanguageResolverUsesDeclaredLanguageThenDetectsText() {
        XCTAssertEqual(
            SpeechLanguageResolver.languageName(for: "Hello", declaredLanguage: "ja"),
            "ja"
        )
        XCTAssertEqual(
            SpeechLanguageResolver.languageName(for: "这是一段中文语音测试。", declaredLanguage: nil),
            "zh-Hans"
        )
        XCTAssertEqual(
            SpeechLanguageResolver.languageName(for: "This is an English voice test.", declaredLanguage: nil),
            "en"
        )
    }

    func testLoadingSameContentCancelsAndOtherContentStarts() {
        XCTAssertEqual(
            SpeechPlaybackPolicy.decision(state: .loading, activeContent: .source, requestedContent: .source),
            .cancel
        )
        XCTAssertEqual(
            SpeechPlaybackPolicy.decision(state: .loading, activeContent: .source, requestedContent: .translation(.youdao)),
            .start
        )
    }

    @MainActor
    func testSpeechSettingsDefaultToSystemAndPersistPerEngine() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SpeechController(settings: SettingsStore(defaults: defaults))

        XCTAssertEqual(controller.engineID, .system)
        let unaffectedAccent = controller.englishAccent(for: .google)
        let unaffectedRate = controller.rate(for: .system)

        controller.selectEngine(.google)
        controller.setEnglishAccent(.uk, for: .youdao)
        controller.setRate(.fast, for: .baidu)

        let reloaded = SpeechController(settings: SettingsStore(defaults: defaults))
        XCTAssertEqual(reloaded.engineID, .google)
        XCTAssertEqual(reloaded.englishAccent(for: .youdao), .uk)
        XCTAssertEqual(reloaded.englishAccent(for: .google), unaffectedAccent, "口音按服务分别保存")
        XCTAssertEqual(reloaded.rate(for: .baidu), .fast)
        XCTAssertEqual(reloaded.rate(for: .system), unaffectedRate)
    }

    func testSpeechEngineCatalogIsConsistent() {
        let ids = SpeechEngineCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids), Set(SpeechEngineID.allCases))
        XCTAssertEqual(ids.count, Set(ids).count)
        let system = SpeechEngineCatalog.descriptor(for: .system)
        XCTAssertFalse(system.isOnline)
        XCTAssertTrue(Set(system.supportedLanguages).isSubset(of: TranslationModel.languages))
        for engine in SpeechEngineCatalog.all {
            XCTAssertTrue(
                Set(engine.supportedLanguages).isSubset(of: TranslationModel.languages),
                "\(engine.id) 的语言须取自 TranslationModel.languages"
            )
            if engine.isOnline {
                XCTAssertNotNil(engine.host)
                XCTAssertNotNil(engine.maximumCharacters)
            }
        }
    }

    func testShortContentMatchesDictionaryLength() {
        for text in ["hello", "give up", "look forward to it", "你好", "天气预报", "你好，世界", "こんにちは", "안녕하세요"] {
            XCTAssertTrue(SpeechLengthPolicy.isShort(text), text)
        }
        for text in ["The cat sat on the mat", "今天天气怎么样", "line one\nline two", String(repeating: "a", count: 81)] {
            XCTAssertFalse(SpeechLengthPolicy.isShort(text), text)
        }
        XCTAssertEqual(
            SpeechPlaybackPolicy.decision(
                state: .speaking, activeContent: .source, requestedContent: .source, activeIsShort: true
            ),
            .restart
        )
    }
}

@MainActor
extension SpeechControllerTests {
    private func cardPlaybackFixture() throws -> (TranslationModel, CardSpeechBackend, [TranslationServiceResult]) {
        _ = NSApplication.shared
        let defaults = try XCTUnwrap(isolatedDefaults())
        let settings = SettingsStore(defaults: defaults)
        settings.speechEngine = .system
        let backend = CardSpeechBackend()
        let speech = SpeechController(settings: settings, systemBackend: backend)
        let model = TranslationModel(credentials: CardSpeechCredentials(), settings: settings, speech: speech)
        model.input = "原文"
        model.resolvedTarget = "fr"
        let results: [TranslationServiceResult] = [(.youdao, "Bonjour"), (.google, "Bonsoir")].map { provider, text in
            TranslationServiceResult(id: provider, title: provider.rawValue, subtitle: "", isTranslation: true,
                phase: .success, text: text, dictionaryEntry: nil, errorMessage: nil, elapsed: nil)
        }
        model.serviceResults = results
        for result in results { model.setServiceExpanded(result.id, expanded: true) }
        return (model, backend, results)
    }

    func testEachCardActionReadsItsOwnResultAndSwitchesPlayback() throws {
        let (model, backend, results) = try cardPlaybackFixture()
        defer { model.speech.stop() }
        let cards = results.map { AppKitServiceCardView(model: model, provider: $0.id) }
        func refreshCards() {
            for (card, result) in zip(cards, results) {
                card.apply(result, hasCurrentResult: true, suppressBody: false, animated: false)
            }
        }
        refreshCards()
        func findSpeechButton(in view: NSView) -> SpeechToggleButton? {
            if let button = view as? SpeechToggleButton { return button }
            return view.subviews.lazy.compactMap { findSpeechButton(in: $0) }.first
        }
        let first = try XCTUnwrap(findSpeechButton(in: cards[0]))
        let second = try XCTUnwrap(findSpeechButton(in: cards[1]))
        XCTAssertTrue(first.isEnabled)
        XCTAssertTrue(second.isEnabled)

        first.performClick(nil)
        refreshCards()
        XCTAssertEqual(backend.spoken, ["Bonjour"])
        XCTAssertEqual(first.appearanceState, .playingShort)
        XCTAssertEqual(second.appearanceState, .idle)
        XCTAssertTrue(model.isServiceExpanded(.youdao))

        second.performClick(nil)
        refreshCards()
        XCTAssertEqual(backend.spoken, ["Bonjour", "Bonsoir"])
        XCTAssertEqual(first.appearanceState, .idle)
        XCTAssertEqual(second.appearanceState, .playingShort)
        XCTAssertTrue(model.isServiceExpanded(.google))
    }

    func testCollapsingOnlyTheReadingCardStopsPlayback() throws {
        let (model, _, _) = try cardPlaybackFixture()
        defer { model.speech.stop() }
        let content = SpeechContent.result(of: .youdao)
        model.speech.toggle(content: content, text: "Bonjour", declaredLanguage: "fr")
        model.setServiceExpanded(.google, expanded: false)
        XCTAssertTrue(model.speech.isActive(content))
        model.setServiceExpanded(.youdao, expanded: false)
        XCTAssertEqual(model.speech.state, .idle)
    }
}

@MainActor private final class CardSpeechBackend: SystemSpeechBackend {
    var onEnd: ((SpeechPlaybackEnd) -> Void)?
    private(set) var spoken: [String] = []
    func speak(_ text: String, languageIdentifier: String?, rate: SpeechRate) { spoken.append(text) }
    func pause() -> Bool { true }
    func resume() -> Bool { true }
    func stop() {}
}

private struct CardSpeechCredentials: CredentialStoring {
    func read(account: String) throws -> String { "" }
    func save(_ value: String, account: String) throws { XCTFail("朗读测试不应写入凭据") }
}
