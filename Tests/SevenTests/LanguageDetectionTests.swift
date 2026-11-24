import XCTest
@testable import Seven

final class LanguageDetectionLiveTests: XCTestCase {
    /// 用 Google 把同一句英文译成目录中的每种语言，再分别交给 Google、百度识别，核对代码对照表。
    func testLiveLanguageDetectionCoversCatalog() async throws {
        guard ProcessInfo.processInfo.environment["SEVEN_LIVE_TRANSLATION_TESTS"] == "1" else {
            throw XCTSkip("Set SEVEN_LIVE_TRANSLATION_TESTS=1 to run online service checks.")
        }
        let translator = GoogleTranslationService()
        let detectors: [(String, OnlineLanguageDetecting)] = [
            ("Google", GoogleLanguageDetector()), ("百度", BaiduLanguageDetector())
        ]
        var report: [String] = []
        for language in LanguageCatalog.all {
            let sample = language.code == "en"
                ? "Good morning, how are you today? I hope you have a wonderful day."
                : try await translator.translate(.init(
                    text: "Good morning, how are you today? I hope you have a wonderful day.",
                    source: "en", target: language.code
                )).text
            for (name, detector) in detectors {
                do {
                    let detected = try await detector.detect(sample)
                    // Google 对中文不分简繁，由本地简繁判断补足（见 TranslationModel）。
                    let matches = detected == language.code
                        || (name == "Google" && LanguageCatalog.isChinese(language.code) && detected.map(LanguageCatalog.isChinese) == true)
                    if !matches { report.append("\(name) \(language.code) → \(detected ?? "目录外")") }
                } catch {
                    report.append("\(name) \(language.code) 请求失败：\(error)")
                }
            }
        }
        print("DETECTION MISMATCHES:\n" + report.joined(separator: "\n"))
        XCTAssertTrue(report.isEmpty, report.joined(separator: "; "))
    }
}

private actor MockDetector: OnlineLanguageDetecting {
    private(set) var calls = 0
    private let result: Result<String?, Error>
    private var gate: CheckedContinuation<Void, Never>?
    private let held: Bool

    init(_ result: Result<String?, Error>, held: Bool = false) {
        self.result = result
        self.held = held
    }

    func detect(_ text: String) async throws -> String? {
        calls += 1
        if held { await withCheckedContinuation { gate = $0 } }
        return try result.get()
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

private actor CountingOnline: OnlineTranslationServing {
    private(set) var requests: [OnlineTranslationRequest] = []
    func translate(_ request: OnlineTranslationRequest) async throws -> OnlineTranslationOutput {
        requests.append(request)
        return .init(text: "译文", dictionaryEntry: nil)
    }
}

private final class NoCredentialStore: CredentialStoring {
    func read(account: String) throws -> String { "" }
    func save(_ value: String, account: String) throws {}
}

private struct EmptyDictionary: DictionaryServing {
    func lookup(_ text: String) async -> DictionaryEntry? { nil }
}

private final class UnusedTranslation: TranslationServing {
    func translateStream(_ request: TranslationRequest, onUpdate: @escaping @Sendable (String) async -> Void) async throws -> String { "" }
}

final class LanguageDetectionPolicyTests: XCTestCase {
    func testTrustedLocalResultsSkipOnlineCheck() {
        for local in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
            XCTAssertFalse(LanguageDetectionPolicy.needsOnlineCheck(local: local, primary: "zh-Hans", secondary: "en"), local)
        }
        XCTAssertTrue(LanguageDetectionPolicy.needsOnlineCheck(local: "id", primary: "zh-Hans", secondary: "en"))
        XCTAssertTrue(LanguageDetectionPolicy.needsOnlineCheck(local: nil, primary: "zh-Hans", secondary: "en"))
    }

    func testOnlySelectedServiceIsRequestedAndStoredValuesRemainCompatible() {
        XCTAssertEqual(LanguageDetectionMode.system.onlineOrder, [])
        XCTAssertEqual(LanguageDetectionMode.google.onlineOrder, [.google])
        XCTAssertEqual(LanguageDetectionMode.baidu.onlineOrder, [.baidu])
        XCTAssertEqual(LanguageDetectionMode(rawValue: "system"), .system)
        XCTAssertEqual(LanguageDetectionMode(rawValue: "google"), .google)
        XCTAssertEqual(LanguageDetectionMode(rawValue: "baidu"), .baidu)
        XCTAssertFalse(LanguageDetectionPolicy.needsOnlineCheck(local: "fr", primary: "fr", secondary: "de"))
        XCTAssertFalse(LanguageDetectionPolicy.needsOnlineCheck(local: "de", primary: "fr", secondary: "de"))
    }

    func testGoogleCodesMapToCatalog() throws {
        func parse(_ src: String) throws -> String? {
            try GoogleLanguageDetector.parse(Data(#"{"src":"\#(src)"}"#.utf8))
        }
        XCTAssertEqual(try parse("sw"), "sw")
        XCTAssertEqual(try parse("iw"), "he")
        XCTAssertEqual(try parse("tl"), "fil")
        XCTAssertEqual(try parse("zh-CN"), "zh-Hans")
        XCTAssertNil(try parse("xx"))
        XCTAssertThrowsError(try GoogleLanguageDetector.parse(Data("<html>Sorry</html>".utf8)))
    }

    func testBaiduCodesMapToCatalog() throws {
        func parse(_ json: String) throws -> String? { try BaiduLanguageDetector.parse(Data(json.utf8)) }
        XCTAssertEqual(try parse(#"{"error":0,"msg":"success","lan":"swa"}"#), "sw")
        XCTAssertEqual(try parse(#"{"error":0,"msg":"success","lan":"per"}"#), "fa")
        XCTAssertEqual(try parse(#"{"error":0,"msg":"success","lan":"jp"}"#), "ja")
        XCTAssertNil(try parse(#"{"error":0,"msg":"success","lan":"xyz"}"#))
        XCTAssertThrowsError(try parse(#"{"error":1,"msg":"fail"}"#))
        XCTAssertEqual(Set(BaiduLanguageDetector.codes.values), Set(LanguageCatalog.codes), "百度对照表应覆盖全部 30 种语言")
    }
}

@MainActor
final class LanguageDetectionModelTests: XCTestCase {
    private let swahili = "Habari ya asubuhi, karibu sana."
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "SevenTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defaults.set(false, forKey: "appleTranslationEnabled")
        defaults.set(false, forKey: "customServiceEnabled")
        defaults.set(true, forKey: "youdaoEnabled")
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    private func makeModel(
        mode: LanguageDetectionMode,
        google: MockDetector,
        baidu: MockDetector,
        youdao: CountingOnline = CountingOnline()
    ) -> TranslationModel {
        defaults.set(mode.rawValue, forKey: LanguageDetectionMode.storageKey)
        return TranslationModel(
            service: UnusedTranslation(), dictionaryService: EmptyDictionary(), youdaoService: youdao,
            credentials: NoCredentialStore(), settings: SettingsStore(defaults: defaults),
            languageDetectors: [.google: google, .baidu: baidu],
            languageDetectionDelay: .milliseconds(30)
        )
    }

    private func waitUntilIdle(_ model: TranslationModel) async throws {
        try await Task.sleep(for: .milliseconds(20))
        for _ in 0..<200 where model.isLoading { try await Task.sleep(for: .milliseconds(10)) }
    }

    func testPreferredLanguageWeightsProduceRequestedShortTextResults() async throws {
        let google = MockDetector(.success("es")), baidu = MockDetector(.success("es"))
        let model = makeModel(mode: .system, google: google, baidu: baidu)
        try model.saveLanguagePair(primary: "zh-Hans", secondary: "en")
        for (text, expected) in [("魔方", "zh-Hans"), ("東京", "ja"), ("こんにちは", "ja"), ("Ok", "en"), ("hola mundo", "es"), ("学生", "zh-Hans")] {
            XCTAssertEqual(LanguageCatalog.detectedCode(for: text, primary: "zh-Hans", secondary: "en"), expected, text)
            model.updateInput(text)
            await model.waitForLanguageDetection()
            XCTAssertEqual(model.displaySource, expected, text)
            XCTAssertEqual(model.sourceLanguageForSpeech, expected, text)
            XCTAssertEqual(SpeechLanguageResolver.languageName(for: text, declaredLanguage: nil, primary: "zh-Hans", secondary: "en"), expected)
            XCTAssertEqual(model.displayTarget, expected == "zh-Hans" ? "en" : "zh-Hans")
            XCTAssertEqual(LanguageRouting.resolvedTarget(for: text, source: "auto", target: "auto", primary: "zh-Hans", secondary: "en"), expected == "zh-Hans" ? "en" : "zh-Hans")
        }
        model.updateInput("魔方"); await model.waitForLanguageDetection()
        try model.saveLanguagePair(primary: "ja", secondary: "en")
        await model.waitForLanguageDetection()
        XCTAssertEqual(model.displaySource, "ja")
        XCTAssertEqual(model.sourceLanguageForSpeech, "ja")
        XCTAssertEqual(LanguageCatalog.detectedCode(for: "魔方", primary: "ja", secondary: "en"), "ja")
        XCTAssertEqual(SpeechLanguageResolver.languageName(for: "魔方", declaredLanguage: nil, primary: "ja", secondary: "en"), "ja")
        let googleCalls = await google.calls, baiduCalls = await baidu.calls
        XCTAssertEqual(googleCalls, 0); XCTAssertEqual(baiduCalls, 0)
    }

    func testPreferredCandidateWeightsDoNotInventCandidatesAndUnifyChinesePreference() {
        XCTAssertEqual(LanguageCatalog.preferredDetectionCandidate(["ja": 0.9], primary: "zh-Hans", secondary: "en"), "ja")
        XCTAssertNil(LanguageCatalog.preferredDetectionCandidate([:], primary: "zh-Hans", secondary: "en"))
        XCTAssertEqual(LanguageCatalog.preferredDetectionCandidate(["zh-Hant": 0.4, "ja": 0.5], primary: "zh-Hans", secondary: "en"), "zh-Hant")
        XCTAssertEqual(LanguageCatalog.preferredDetectionCandidate(["zh-Hans": 0.4, "ja": 0.5], primary: "zh-Hant", secondary: "en"), "zh-Hans")
        XCTAssertEqual(LanguageCatalog.preferredDetectionCandidate(["en": 0.3, "fr": 0.5], primary: "zh-Hans", secondary: "en"), "en")
        XCTAssertEqual(LanguageCatalog.detectedCode(for: "這是一段繁體中文。", primary: "zh-Hans", secondary: "en"), "zh-Hant")
    }

    func testDetectionModeSelectionPersistsImmediately() {
        let model = makeModel(mode: .system, google: MockDetector(.success("es")), baidu: MockDetector(.success("es")))
        for mode in [LanguageDetectionMode.baidu, .google, .system] {
            model.languageDetectionMode = mode
            XCTAssertEqual(SettingsStore(defaults: defaults).languageDetectionMode, mode)
            XCTAssertEqual(defaults.string(forKey: "languageDetection.v1"), mode.rawValue)
        }
    }

    func testUntrustedSpanishOnlyUsesSelectedDetector() async {
        let text = "Buenos días, ¿cómo estás? Espero que tengas un día maravilloso."
        XCTAssertEqual(LanguageCatalog.detectedCode(for: text), "es")
        XCTAssertTrue(LanguageDetectionPolicy.needsOnlineCheck(local: "es", primary: "zh-Hans", secondary: "en"))
        for mode in LanguageDetectionMode.allCases {
            let google = MockDetector(.success("es")), baidu = MockDetector(.success("es"))
            let model = makeModel(mode: mode, google: google, baidu: baidu)
            model.updateInput(text)
            await model.waitForLanguageDetection()
            XCTAssertEqual(model.detectedSource, "es")
            let googleCalls = await google.calls, baiduCalls = await baidu.calls
            XCTAssertEqual(googleCalls, mode == .google ? 1 : 0, mode.rawValue)
            XCTAssertEqual(baiduCalls, mode == .baidu ? 1 : 0, mode.rawValue)
        }
    }

    func testSystemLocalResultIsIndonesianForSwahili() {
        XCTAssertEqual(LanguageCatalog.detectedCode(for: swahili), "id", "前提：系统识别会把斯瓦希里语误认为印尼语")
    }

    func testGoogleCorrectsSwahiliBeforeTranslating() async throws {
        let google = MockDetector(.success("sw")), baidu = MockDetector(.success("id"))
        let youdao = CountingOnline()
        let model = makeModel(mode: .google, google: google, baidu: baidu, youdao: youdao)
        model.updateInput(swahili)
        model.translate()
        try await waitUntilIdle(model)

        XCTAssertEqual(model.detectedSource, "sw")
        XCTAssertEqual(model.serviceResults.first { $0.id == .youdao }?.errorMessage, "有道翻译不支持斯瓦希里语")
        let googleCalls = await google.calls, baiduCalls = await baidu.calls, requests = await youdao.requests
        XCTAssertEqual(googleCalls, 1)
        XCTAssertEqual(baiduCalls, 0)
        XCTAssertTrue(requests.isEmpty)

        model.translate()
        try await waitUntilIdle(model)
        let again = await google.calls
        XCTAssertEqual(again, 1, "同一段原文不重复联网识别")
    }

    func testTrustedLanguagesAndSystemModeDoNotGoOnline() async throws {
        let google = MockDetector(.success("sw")), baidu = MockDetector(.success("sw"))
        let model = makeModel(mode: .google, google: google, baidu: baidu)
        model.updateInput("Good morning, how are you today?")
        model.translate()
        try await waitUntilIdle(model)
        let trustedCalls = await google.calls
        XCTAssertEqual(trustedCalls, 0, "英文直接采用系统识别")

        let systemGoogle = MockDetector(.success("sw"))
        let systemModel = makeModel(mode: .system, google: systemGoogle, baidu: MockDetector(.success("sw")))
        systemModel.updateInput(swahili)
        systemModel.translate()
        try await waitUntilIdle(systemModel)
        let systemCalls = await systemGoogle.calls
        XCTAssertEqual(systemCalls, 0)
        XCTAssertEqual(systemModel.detectedSource, "id")
    }

    func testJapaneseAndKoreanDoNotRequestOnlineOptimization() async {
        let google = MockDetector(.success("sw")), baidu = MockDetector(.success("sw"))
        let model = makeModel(mode: .google, google: google, baidu: baidu)
        for (text, code) in [("今日は天気が良いので、公園を散歩しましょう。", "ja"), ("오늘은 날씨가 좋아서 공원에서 산책하고 싶습니다.", "ko")] {
            XCTAssertEqual(LanguageCatalog.detectedCode(for: text), code)
            model.updateInput(text)
            await model.waitForLanguageDetection()
            XCTAssertEqual(model.detectedSource, code)
        }
        let googleCalls = await google.calls, baiduCalls = await baidu.calls
        XCTAssertEqual(googleCalls, 0)
        XCTAssertEqual(baiduCalls, 0)
    }

    func testGoogleFailureUsesLocalResultWithoutCallingBaidu() async throws {
        let google = MockDetector(.failure(TranslationError.malformed)), baidu = MockDetector(.success("sw"))
        let model = makeModel(mode: .google, google: google, baidu: baidu)
        model.updateInput(swahili)
        model.translate()
        try await waitUntilIdle(model)
        XCTAssertEqual(model.detectedSource, "id", "所选服务失败时采用本机识别")
        XCTAssertFalse(model.serviceResults.isEmpty, "识别失败也照常翻译")
        let googleCalls = await google.calls, baiduCalls = await baidu.calls
        XCTAssertEqual(googleCalls, 1)
        XCTAssertEqual(baiduCalls, 0)
    }

    func testBaiduOptimizationDoesNotRequestGoogle() async {
        let google = MockDetector(.success("sw")), baidu = MockDetector(.success("sw"))
        let model = makeModel(mode: .baidu, google: google, baidu: baidu)
        model.updateInput(swahili)
        await model.waitForLanguageDetection()
        XCTAssertEqual(model.detectedSource, "sw")
        let googleCalls = await google.calls, baiduCalls = await baidu.calls
        XCTAssertEqual(googleCalls, 0)
        XCTAssertEqual(baiduCalls, 1)
    }

    func testTypingPauseDetectsOnlineWithoutPressingEnter() async throws {
        let google = MockDetector(.success("sw"))
        let model = makeModel(mode: .google, google: google, baidu: MockDetector(.success("sw")))
        model.updateInput(swahili)
        XCTAssertTrue(model.isSourceLanguagePending, "识别完成前朗读应等待")
        XCTAssertNil(model.detectedSource, "输入过程中不显示离线的误判结果")

        await model.waitForLanguageDetection()
        XCTAssertEqual(model.detectedSource, "sw")
        XCTAssertFalse(model.isSourceLanguagePending)
        XCTAssertEqual(model.sourceLanguageForSpeech, "sw", "朗读按斯瓦希里语，不按误判的印尼语")
        XCTAssertTrue(model.serviceResults.isEmpty, "只识别，不自动翻译")

        model.translate()
        try await waitUntilIdle(model)
        let calls = await google.calls
        XCTAssertEqual(calls, 1, "按回车时直接用已识别的结果")
    }

    func testPressingEnterDuringOnlineDetectionWaitsForIt() async throws {
        let google = MockDetector(.success("sw"), held: true)
        let youdao = CountingOnline()
        let model = makeModel(mode: .google, google: google, baidu: MockDetector(.success("sw")), youdao: youdao)
        model.updateInput(swahili)
        for _ in 0..<100 where await google.calls < 1 { try await Task.sleep(for: .milliseconds(5)) }

        model.translate()
        XCTAssertEqual(model.status, "正在识别语言…")
        await google.release()
        try await waitUntilIdle(model)

        let calls = await google.calls
        XCTAssertEqual(calls, 1, "不重复请求")
        XCTAssertEqual(model.detectedSource, "sw")
        XCTAssertEqual(model.serviceResults.first { $0.id == .youdao }?.errorMessage, "有道翻译不支持斯瓦希里语")
    }

    func testSwitchingSourceCancelsHeldDetectionAndDiscardsItsResult() async throws {
        let google = MockDetector(.success("sw"), held: true)
        let model = makeModel(mode: .google, google: google, baidu: MockDetector(.success("sw")))
        model.updateInput(swahili)
        for _ in 0..<100 where await google.calls < 1 { try await Task.sleep(for: .milliseconds(5)) }
        let calls = await google.calls
        XCTAssertEqual(calls, 1)
        let oldDetection = try XCTUnwrap(model.detectionTask)

        model.setSource("fr")
        let detectedAfterSwitch = model.detectedSource
        XCTAssertTrue(oldDetection.isCancelled)
        XCTAssertNil(model.detectionTask)
        XCTAssertNil(model.detectingText)
        XCTAssertFalse(model.isDetectingOnline)
        XCTAssertNil(model.confirmedDetection)

        await google.release()
        await oldDetection.value
        XCTAssertEqual(model.source, "fr")
        XCTAssertEqual(model.displaySource, "fr")
        XCTAssertEqual(LanguageBarLabel.source(source: model.source, detected: model.detectedSource, hasText: true),
                       .init(name: "法语", note: nil))
        XCTAssertEqual(model.detectedSource, detectedAfterSwitch, "已取消的识别不能改写语言栏状态")
        XCTAssertNil(model.confirmedDetection, "已取消的识别不能写入缓存")
    }

    func testCancellingTranslationStillAllowsHeldDetectionToFinish() async throws {
        let google = MockDetector(.success("sw"), held: true)
        let youdao = CountingOnline()
        let model = makeModel(mode: .google, google: google, baidu: MockDetector(.success("sw")), youdao: youdao)
        model.updateInput(swahili)
        for _ in 0..<100 where await google.calls < 1 { try await Task.sleep(for: .milliseconds(5)) }
        let detection = try XCTUnwrap(model.detectionTask)
        model.translate()
        model.cancel()
        XCTAssertFalse(detection.isCancelled, "普通取消翻译不得取消语言识别")

        await google.release()
        await detection.value
        XCTAssertEqual(model.detectedSource, "sw")
        XCTAssertEqual(model.confirmedDetection?.text, swahili)
        XCTAssertEqual(model.confirmedDetection?.code, "sw")
        XCTAssertFalse(model.isLoading)
        let requests = await youdao.requests
        XCTAssertTrue(requests.isEmpty, "取消后识别完成不应自动开始翻译")
    }

    func testSwitchingToSystemMidDetectionStopsFurtherOnlineRequests() async throws {
        let google = MockDetector(.failure(TranslationError.malformed), held: true)
        let baidu = MockDetector(.success("sw"))
        let model = makeModel(mode: .google, google: google, baidu: baidu)
        model.updateInput(swahili)
        for _ in 0..<100 where await google.calls < 1 { try await Task.sleep(for: .milliseconds(5)) }

        model.languageDetectionMode = .system
        await google.release()
        await model.waitForLanguageDetection()
        try await Task.sleep(for: .milliseconds(50))

        let baiduCalls = await baidu.calls
        XCTAssertEqual(baiduCalls, 0, "切回系统后不能再把原文发给百度")
        XCTAssertEqual(model.detectedSource, "id")
        XCTAssertFalse(model.isSourceLanguagePending)
    }

    func testSwitchingToGoogleAfterDetectionRedetectsCurrentText() async throws {
        let google = MockDetector(.success("sw"))
        let model = makeModel(mode: .system, google: google, baidu: MockDetector(.success("sw")))
        model.updateInput(swahili)
        await model.waitForLanguageDetection()
        XCTAssertEqual(model.detectedSource, "id")

        model.languageDetectionMode = .google
        await model.waitForLanguageDetection()
        XCTAssertEqual(model.detectedSource, "sw")
        XCTAssertFalse(model.isSourceLanguagePending, "不能一直停在“正在识别语言…”")
    }

    func testRetryDuringDetectionWaitsAndOnlyRestartsThatService() async throws {
        let google = MockDetector(.success("sw"), held: true)
        let youdao = CountingOnline()
        let model = makeModel(mode: .system, google: google, baidu: MockDetector(.success("sw")), youdao: youdao)
        model.updateInput(swahili)
        model.translate()
        try await waitUntilIdle(model)
        let first = await youdao.requests.count
        XCTAssertEqual(first, 1, "系统识别为印尼语时有道照常请求")

        model.languageDetectionMode = .google
        for _ in 0..<100 where await google.calls < 1 { try await Task.sleep(for: .milliseconds(5)) }
        model.retryResult(.youdao)
        XCTAssertEqual(model.serviceResults.first { $0.id == .youdao }?.phase, .loading)
        let during = await youdao.requests.count
        XCTAssertEqual(during, 1, "识别完成前不按误判的语言请求")

        await google.release()
        try await waitUntilIdle(model)
        let after = await youdao.requests.count
        XCTAssertEqual(after, 1)
        XCTAssertEqual(model.serviceResults.first { $0.id == .youdao }?.errorMessage, "有道翻译不支持斯瓦希里语")
    }

    /// 服务在语言识别完成前被停用时，加载状态必须复位。
    func testServiceDisabledWhileWaitingForDetectionDoesNotStayLoading() async throws {
        let google = MockDetector(.success("sw"), held: true)
        let model = makeModel(mode: .google, google: google, baidu: MockDetector(.success("sw")))
        model.updateInput(swahili)
        for _ in 0..<100 where await google.calls < 1 { try await Task.sleep(for: .milliseconds(5)) }

        model.setServiceExpanded(.youdao, expanded: false)
        model.setServiceExpanded(.youdao, expanded: true)
        XCTAssertTrue(model.isLoading, "展开后进入等待识别")
        model.setServiceEnabled(.youdao, enabled: false)

        await google.release()
        await model.waitForLanguageDetection()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(model.isLoading, "没有任何请求在跑时不能一直显示加载中")
        XCTAssertNotEqual(model.status, "正在识别语言…")
    }

    func testChangingInputDuringDetectionDiscardsStaleResult() async throws {
        let google = MockDetector(.success("sw"), held: true)
        let model = makeModel(mode: .google, google: google, baidu: MockDetector(.success("sw")))
        model.updateInput(swahili)
        model.translate()
        for _ in 0..<100 where await google.calls < 1 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.status, "正在识别语言…")

        model.updateInput("Good morning")
        await google.release()
        await model.waitForLanguageDetection()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.detectedSource, "en", "旧原文的识别结果不能套到新原文上")
        XCTAssertTrue(model.serviceResults.isEmpty, "原文已改，不应按旧识别结果自动开始翻译")
    }
}
