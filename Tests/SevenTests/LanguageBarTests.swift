import Foundation
import XCTest
@testable import Seven

private final class NoCredentials: CredentialStoring {
    func read(account: String) throws -> String { "" }
    func save(_ value: String, account: String) throws {}
}

private actor RecordingOnlineService: OnlineTranslationServing {
    private(set) var requests: [OnlineTranslationRequest] = []
    let response: String

    init(response: String) { self.response = response }

    func translate(_ request: OnlineTranslationRequest) async throws -> OnlineTranslationOutput {
        requests.append(request)
        return .init(text: response, dictionaryEntry: nil)
    }
}

private struct UnsupportedOnlineService: OnlineTranslationServing {
    func translate(_ request: OnlineTranslationRequest) async throws -> OnlineTranslationOutput {
        throw TranslationError.unsupportedLanguage(.key("youdaoTranslateDoesNotSupportTheLanguage"))
    }
}

/// First request stalls and returns a normal network error once released; subsequent requests succeed immediately.
private actor FirstCallLateFailureService: OnlineTranslationServing {
    private(set) var calls = 0
    private var gate: CheckedContinuation<Void, Never>?

    func translate(_ request: OnlineTranslationRequest) async throws -> OnlineTranslationOutput {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation { gate = $0 }
            throw TranslationError.transport("网络错误")
        }
        return .init(text: "新结果", dictionaryEntry: nil)
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

/// Keeps the request suspended until release is called so the current translation round stays in progress.
private actor HeldOnlineService: OnlineTranslationServing {
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    func translate(_ request: OnlineTranslationRequest) async throws -> OnlineTranslationOutput {
        if !released { await withCheckedContinuation { gate = $0 } }
        return .init(text: "有道结果", dictionaryEntry: nil)
    }

    func release() {
        released = true
        gate?.resume()
        gate = nil
    }
}

private struct NoDictionary: DictionaryServing {
    func lookup(_ text: String) async -> DictionaryEntry? { nil }
}

private final class UnusedService: TranslationServing {
    func translateStream(_ request: TranslationRequest, onUpdate: @escaping @Sendable (String) async -> Void) async throws -> String { "" }
}

final class ServiceLanguageSupportTests: XCTestCase {
    func testServiceSpecificSupport() {
        XCTAssertEqual(ServiceLanguageSupport.unsupportedLanguage(.youdao, source: "en", target: "sw"), "sw")
        XCTAssertEqual(ServiceLanguageSupport.unsupportedLanguage(.youdao, source: "sw", target: "zh-Hans"), "sw")
        XCTAssertNil(ServiceLanguageSupport.unsupportedLanguage(.google, source: "en", target: "sw"))
        XCTAssertEqual(ServiceLanguageSupport.unsupportedLanguage(.appleTranslation, source: "en", target: "sv"), "sv")
        XCTAssertNil(ServiceLanguageSupport.unsupportedLanguage(.compatible, source: "en", target: "sw"))
        XCTAssertNil(ServiceLanguageSupport.unsupportedLanguage(.compatible, source: "fil", target: "sw"))
    }

    func testYoudaoPortugueseOnlyWithChinese() {
        XCTAssertEqual(ServiceLanguageSupport.unsupportedLanguage(.youdao, source: "en", target: "pt"), "pt")
        XCTAssertEqual(ServiceLanguageSupport.unsupportedLanguage(.youdao, source: "pt", target: "en"), "pt")
        XCTAssertNil(ServiceLanguageSupport.unsupportedLanguage(.youdao, source: "zh-Hans", target: "pt"))
        XCTAssertNil(ServiceLanguageSupport.unsupportedLanguage(.youdao, source: "pt", target: "zh-Hant"))
        XCTAssertNil(ServiceLanguageSupport.unsupportedLanguage(.youdao, source: "auto", target: "pt"), "检测不出源语言时视为支持")
    }
}

final class LanguageBarLabelTests: XCTestCase {
    func testSwapSymbolFallsBackToSystemSymbolWithoutAppBundle() {
        XCTAssertNotNil(Design.Icon.symbol(Design.Icon.swapLanguages))
        XCTAssertNil(Design.Icon.symbol("seven.does-not-exist"))
    }

    func testHistoryDisplayNameAcceptsCodesAndLegacyNames() {
        XCTAssertEqual(LanguageCatalog.displayName(stored: "zh-Hans"), LanguageCatalog.name("zh-Hans"))
        XCTAssertEqual(LanguageCatalog.displayName(stored: "English"), LanguageCatalog.name("en"))
        XCTAssertEqual(LanguageCatalog.displayName(stored: "润色"), "润色")
    }
}

@MainActor
final class LanguageBarModelTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "SevenTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(isolatedDefaults(suiteName: suiteName))
        SettingsStore(defaults: defaults).languageDetectionMode = .system
        defaults.set(false, forKey: "appleTranslationEnabled")
        defaults.set(false, forKey: "customServiceEnabled")
        defaults.set(true, forKey: "youdaoEnabled")
        defaults.set(false, forKey: "googleEnabled")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel(_ youdao: RecordingOnlineService) -> TranslationModel {
        TranslationModel(
            service: UnusedService(),
            dictionaryService: NoDictionary(),
            youdaoService: youdao,
            credentials: NoCredentials(),
            settings: SettingsStore(defaults: defaults),
            languageDetectionDelay: .milliseconds(30)
        )
    }

    private func waitUntilIdle(_ model: TranslationModel) async throws {
        try await Task.sleep(for: .milliseconds(20))
        for _ in 0..<100 where model.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Detection result appears after input stops and the debounce delay elapses.
    func testLanguageBarUpdatesAfterTypingPause() async {
        let model = makeModel(RecordingOnlineService(response: "x"))
        model.updateInput("The quick brown fox jumps over the lazy dog.")
        XCTAssertNil(model.detectedSource, "停顿前不显示")
        await model.waitForLanguageDetection()
        XCTAssertEqual(model.detectedSource, "en")
        XCTAssertEqual(model.displaySource, "en")
        XCTAssertEqual(model.displayTarget, "zh-Hans")

        model.updateInput("这是一段完全不同语言的中文原文。")
        await model.waitForLanguageDetection()
        XCTAssertEqual(model.detectedSource, "zh-Hans")
        XCTAssertEqual(model.displayTarget, "en")

        model.updateInput("")
        XCTAssertNil(model.detectedSource)
        XCTAssertNil(model.displayTarget)
    }

    func testHistoryStoresDetectedLanguageCodes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = HistoryStore(fileURL: directory.appendingPathComponent("history.json"), defaults: defaults)
        let model = TranslationModel(
            service: UnusedService(),
            dictionaryService: NoDictionary(),
            youdaoService: RecordingOnlineService(response: "你好，世界"),
            credentials: NoCredentials(),
            settings: SettingsStore(defaults: defaults),
            logger: NoopDiagnosticLogger(),
            history: history
        )
        model.updateInput("Hello, world")

        model.translate()
        try await waitUntilIdle(model)

        XCTAssertEqual(history.records.first?.sourceLanguage, "en")
        XCTAssertEqual(history.records.first?.targetLanguage, "zh-Hans")
    }

    func testChangingTargetRetranslatesImmediatelyAndIsRemembered() async throws {
        let youdao = RecordingOnlineService(response: "こんにちは")
        let model = makeModel(youdao)
        model.updateInput("Hello")

        model.setTarget("ja")
        try await waitUntilIdle(model)

        let requests = await youdao.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.target, "ja")

        let reopened = makeModel(RecordingOnlineService(response: "x"))
        XCTAssertEqual(reopened.target, "ja")
        XCTAssertEqual(reopened.source, LanguageCatalog.automatic)
    }

    func testChangingLanguageWithoutInputDoesNotTranslate() async throws {
        let youdao = RecordingOnlineService(response: "x")
        let model = makeModel(youdao)

        model.setSource("en")
        try await waitUntilIdle(model)

        let requests = await youdao.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testSwapNeedsResultOrTwoFixedLanguages() {
        let model = makeModel(RecordingOnlineService(response: "x"))
        XCTAssertFalse(model.canSwapLanguages)

        model.setSource("en")
        model.setTarget("ja")
        XCTAssertTrue(model.canSwapLanguages)

        model.swapLanguages()
        XCTAssertEqual(model.source, "ja")
        XCTAssertEqual(model.target, "en")
    }

    func testSwapInAutomaticModeUsesTopResultAsNewInput() async throws {
        let youdao = RecordingOnlineService(response: "你好，世界")
        let model = makeModel(youdao)
        model.updateInput("Hello, world")
        model.translate()
        try await waitUntilIdle(model)

        XCTAssertTrue(model.canSwapLanguages)
        XCTAssertEqual(model.swapTitle, L10n.format("swapWithTheTranslationFrom", ServiceProvider.youdao.title))

        model.swapLanguages()
        try await waitUntilIdle(model)

        XCTAssertEqual(model.input, "你好，世界")
        XCTAssertEqual(model.source, LanguageCatalog.automatic)
        XCTAssertEqual(model.target, TranslationModel.automaticTarget)
        let requests = await youdao.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.text, "你好，世界")
    }

    func testUnsupportedTargetSkipsServiceWithoutRequest() async throws {
        let youdao = RecordingOnlineService(response: "x")
        let model = makeModel(youdao)
        model.updateInput("Hello")

        model.setTarget("sw")
        try await waitUntilIdle(model)

        let result = try XCTUnwrap(model.serviceResults.first { $0.id == .youdao })
        XCTAssertEqual(result.phase, .skipped)
        XCTAssertEqual(result.issue, .key("translation.unsupportedLanguage", .provider(.youdao), .language("sw")))
        let requests = await youdao.requests
        XCTAssertTrue(requests.isEmpty)

        model.retryResult(.youdao)
        let afterRetry = await youdao.requests
        XCTAssertTrue(afterRetry.isEmpty, "重试与展开也不应发出请求")
        XCTAssertEqual(model.serviceResults.first { $0.id == .youdao }?.phase, .skipped)
    }

    func testCommonLanguagesAppendRemoveAndPersistOrder() {
        let model = makeModel(RecordingOnlineService(response: "x"))
        let initial = model.commonLanguages
        guard let removed = initial.first, model.otherLanguages.count >= 2 else {
            return XCTFail("需要已有常用语言和两种待添加语言")
        }
        XCTAssertEqual(model.otherLanguages, LanguageCatalog.codes.filter { !initial.contains($0) })
        let additions = Array(model.otherLanguages.prefix(2))
        for code in additions { model.setCommonLanguage(code, isCommon: true) }
        model.setCommonLanguage(removed, isCommon: false)
        let expected = initial.filter { $0 != removed } + additions
        XCTAssertEqual(model.commonLanguages, expected)

        let reopened = makeModel(RecordingOnlineService(response: "x"))
        XCTAssertEqual(reopened.commonLanguages, expected)
    }

    func testLanguageChoicesSaveImmediatelyAndSwapDuplicates() {
        let model = makeModel(RecordingOnlineService(response: "x"))
        model.setPrimaryLanguage("ja")
        XCTAssertEqual(makeModel(RecordingOnlineService(response: "x")).primaryLanguage, "ja")
        model.setSecondaryLanguage("ja")
        XCTAssertEqual(model.secondaryLanguage, "ja")
        XCTAssertEqual(model.primaryLanguage, "en")
        model.setPrimaryLanguage("ja")
        XCTAssertEqual(model.primaryLanguage, "ja")
        XCTAssertEqual(model.secondaryLanguage, "en")
        let reopened = makeModel(RecordingOnlineService(response: "x"))
        XCTAssertEqual(reopened.primaryLanguage, "ja")
        XCTAssertEqual(reopened.secondaryLanguage, "en")
    }

    func testMoveCommonLanguagesAndIgnoreInvalidEdits() {
        let model = makeModel(RecordingOnlineService(response: "x"))
        let initial = model.commonLanguages
        model.moveCommonLanguage(from: IndexSet(integer: 2), to: 0)
        let expected = [initial[2]] + initial.enumerated().filter { $0.offset != 2 }.map(\.element)
        XCTAssertEqual(model.commonLanguages, expected)
        model.moveCommonLanguage(from: IndexSet(integer: 100), to: 0)
        model.moveCommonLanguage(from: IndexSet(integer: 0), to: -1)
        model.setCommonLanguage("xx", isCommon: true)
        model.setCommonLanguage(expected[0], isCommon: true)
        XCTAssertEqual(model.commonLanguages, expected)
        XCTAssertEqual(makeModel(RecordingOnlineService(response: "x")).commonLanguages, expected)
        XCTAssertEqual(model.otherLanguages, LanguageCatalog.codes.filter { !expected.contains($0) })
    }

    func testLastCommonLanguageCannotBeRemoved() {
        let model = makeModel(RecordingOnlineService(response: "x"))
        let initial = model.commonLanguages
        for code in initial { model.setCommonLanguage(code, isCommon: false) }
        XCTAssertEqual(model.commonLanguages, Array(initial.suffix(1)))
        XCTAssertEqual(model.commonLanguages.count, 1)
    }

    func testInvalidStoredCommonLanguagesAreIgnored() {
        defaults.set(["xx", "ja", "en"], forKey: "commonLanguages.v1")
        XCTAssertEqual(makeModel(RecordingOnlineService(response: "x")).commonLanguages, ["ja", "en"])
        defaults.set(["xx"], forKey: "commonLanguages.v1")
        XCTAssertEqual(makeModel(RecordingOnlineService(response: "x")).commonLanguages, LanguageCatalog.defaultCommon)
    }

    func testLanguageRowsIsolateRightToLeftNamesAndKeepChineseOnRight() {
        for code in ["ar", "fa", "he", "ur"] {
            let choice = SettingsLanguageChoice(code: code)
            XCTAssertEqual(Locale.Language(identifier: code).characterDirection, .rightToLeft)
            let isolatedName = "\u{2068}" + choice.nativeName + "\u{2069}"
            XCTAssertTrue(choice.rowText().string.hasPrefix(isolatedName))
            XCTAssertTrue(choice.rowText().string.hasSuffix(choice.title))
            let paragraph = choice.rowText().attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertEqual(paragraph?.baseWritingDirection, .leftToRight)
            XCTAssertEqual(SettingsLanguageChoice.displayNativeName(choice.nativeName, code: code), "\u{2068}" + choice.nativeName + "\u{2069}")
            XCTAssertEqual(SettingsLanguageChoice.filtered(codes: [code], query: choice.nativeName).map(\.id), [code])
        }
        XCTAssertEqual(SettingsLanguageChoice.displayNativeName("Français", code: "fr"), "Français")
    }

    func testLanguageNativeNamesCapitalizeOnlyFirstCharacter() {
        for code in ["fr", "es", "ru", "pt", "ja", "zh-Hans"] {
            let locale = Locale(identifier: code)
            let original = locale.localizedString(forIdentifier: code)!
            let expected = String(original.prefix(1)).capitalized(with: locale) + original.dropFirst()
            XCTAssertEqual(SettingsLanguageChoice.nativeName(for: code), expected)
            XCTAssertEqual(SettingsLanguageChoice(code: code).nativeName, expected)
        }
    }

    func testLanguageAdditionFiltersNamesCodesAndKeepsSelectionInCatalogOrder() {
        let model = makeModel(RecordingOnlineService(response: "x"))
        model.setCommonLanguage("fr", isCommon: false)
        let available = model.otherLanguages
        XCTAssertEqual(SettingsLanguageChoice.filtered(codes: available, query: "葡萄牙").map(\.id), ["pt"])
        XCTAssertEqual(SettingsLanguageChoice.filtered(codes: available, query: "francais").map(\.id), ["fr"], "本地名称搜索忽略变音符号")
        XCTAssertEqual(SettingsLanguageChoice.filtered(codes: available, query: "PORTUGUESE").map(\.id), ["pt"], "英文名称搜索忽略大小写")
        XCTAssertEqual(SettingsLanguageChoice.filtered(codes: available, query: "PT").map(\.id), ["pt"])
        let choices = SettingsLanguageChoice.filtered(codes: available, query: "")
        XCTAssertTrue(Set(choices.map(\.id)).isDisjoint(with: Set(model.commonLanguages)), "已添加语言不出现在弹窗")
        let before = model.commonLanguages
        let ordered = SettingsLanguageChoice.selectedCodes(in: choices, selection: ["sw", "pt", "fr"])
        XCTAssertEqual(ordered, ["fr", "pt", "sw"])
        for code in ordered { model.setCommonLanguage(code, isCommon: true) }
        XCTAssertEqual(model.commonLanguages, before + ordered)
        XCTAssertEqual(makeModel(RecordingOnlineService(response: "x")).commonLanguages, before + ordered)
    }

    func testShortChineseWithoutTraditionalCharactersIsSimplified() {
        XCTAssertEqual(LanguageCatalog.detectedCode(for: "你好"), "zh-Hans")
        XCTAssertEqual(LanguageCatalog.detectedCode(for: "這是一段繁體中文的句子。"), "zh-Hant")
        XCTAssertEqual(LanguageCatalog.detectedCode(for: "这是一段简体中文的句子。"), "zh-Hans")
    }

    func testYoudaoUnsupportedLanguageErrorIsShownAsSkipped() async throws {
        let model = TranslationModel(
            service: UnusedService(),
            dictionaryService: NoDictionary(),
            youdaoService: UnsupportedOnlineService(),
            credentials: NoCredentials(),
            settings: SettingsStore(defaults: defaults)
        )
        model.updateInput("Habari")
        model.translate()
        try await waitUntilIdle(model)

        let result = try XCTUnwrap(model.serviceResults.first { $0.id == .youdao })
        XCTAssertEqual(result.phase, .skipped)
        XCTAssertEqual(result.issue, .key("youdaoTranslateDoesNotSupportTheLanguage"))
        XCTAssertNil(model.errorMessage)
    }

    func testDictionarySkippedWhenSourceIsKnownNonEnglish() async throws {
        defaults.set(true, forKey: "ecdictEnabled")
        let model = makeModel(RecordingOnlineService(response: "x"))
        model.updateInput("Habari")
        model.setSource("sw")
        try await waitUntilIdle(model)

        let result = try XCTUnwrap(model.serviceResults.first { $0.id == .ecdict })
        XCTAssertEqual(result.phase, .skipped)
        XCTAssertEqual(result.issue, TranslationModel.dictionaryInputIssue)
    }

    func testEnablingAndDisablingServicesUpdatesShownResults() async throws {
        let youdao = RecordingOnlineService(response: "有道结果")
        let google = RecordingOnlineService(response: "Google 结果")
        let model = TranslationModel(
            service: UnusedService(),
            dictionaryService: NoDictionary(),
            youdaoService: youdao,
            googleService: google,
            credentials: NoCredentials(),
            settings: SettingsStore(defaults: defaults)
        )
        model.updateInput("Hello")
        model.translate()
        try await waitUntilIdle(model)
        XCTAssertEqual(model.displayedServiceResults.map(\.id), [.youdao])

        model.setServiceEnabled(.google, enabled: true)
        try await waitUntilIdle(model)
        XCTAssertEqual(model.displayedServiceResults.map(\.id), [.youdao, .google])
        XCTAssertEqual(model.displayedServiceResults.map(\.phase), [.success, .success])
        let youdaoRequests = await youdao.requests
        let googleRequests = await google.requests
        XCTAssertEqual(youdaoRequests.count, 1, "已有结果的服务不重新请求")
        XCTAssertEqual(googleRequests.count, 1, "只为新启用的服务请求一次")

        model.setServiceEnabled(.youdao, enabled: false)
        XCTAssertEqual(model.displayedServiceResults.map(\.id), [.google])
        XCTAssertEqual(model.serviceResults.first(where: { $0.id == .google })?.text, "Google 结果")
    }

    func testEnablingCollapsedServiceStaysPausedWithoutRequest() async throws {
        let google = RecordingOnlineService(response: "Google 结果")
        let model = TranslationModel(
            service: UnusedService(), dictionaryService: NoDictionary(),
            youdaoService: RecordingOnlineService(response: "有道结果"), googleService: google,
            credentials: NoCredentials(), settings: SettingsStore(defaults: defaults)
        )
        model.setServiceExpanded(.google, expanded: false)
        model.updateInput("Hello")
        model.translate()
        try await waitUntilIdle(model)

        model.setServiceEnabled(.google, enabled: true)
        try await waitUntilIdle(model)

        let result = try XCTUnwrap(model.serviceResults.first { $0.id == .google })
        XCTAssertEqual(result.phase, .skipped)
        let requests = await google.requests
        XCTAssertTrue(requests.isEmpty, "收起的卡片不应发请求")
    }

    /// Rapidly disabling and re-enabling Google while the same translation round is still active (Youdao still pending):
    /// a late normal error from the old request must not overwrite the new result after re-enabling.
    func testLateErrorFromCancelledRequestDoesNotOverwriteNewResult() async throws {
        let youdao = HeldOnlineService()
        let google = FirstCallLateFailureService()
        let model = TranslationModel(
            service: UnusedService(), dictionaryService: NoDictionary(),
            youdaoService: youdao, googleService: google,
            credentials: NoCredentials(), settings: SettingsStore(defaults: defaults)
        )
        model.updateInput("Hello")
        model.translate()

        model.setServiceEnabled(.google, enabled: true)
        for _ in 0..<100 where await google.calls < 1 { try await Task.sleep(for: .milliseconds(5)) }
        model.setServiceEnabled(.google, enabled: false)
        model.setServiceEnabled(.google, enabled: true)
        for _ in 0..<100 where model.serviceResults.first(where: { $0.id == .google })?.phase != .success {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.serviceResults.first { $0.id == .google }?.text, "新结果")

        await google.release()
        try await Task.sleep(for: .milliseconds(50))
        let result = try XCTUnwrap(model.serviceResults.first { $0.id == .google })
        XCTAssertEqual(result.phase, .success, "旧请求迟到的错误不应覆盖新结果")
        XCTAssertEqual(result.text, "新结果")

        await youdao.release()
        try await waitUntilIdle(model)
    }

    func testInvalidStoredLanguageFallsBackToAutomatic() {
        defaults.set("xx-unknown", forKey: "targetLanguage.v1")
        let model = makeModel(RecordingOnlineService(response: "x"))
        XCTAssertEqual(model.target, TranslationModel.automaticTarget)
    }
}
