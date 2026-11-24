import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import Seven

@MainActor
private final class RecordingSystemBackend: SystemSpeechBackend {
    var onEnd: ((SpeechPlaybackEnd) -> Void)?
    private(set) var spoken: [(text: String, language: String?, rate: SpeechRate)] = []
    private(set) var stopCount = 0

    func speak(_ text: String, languageIdentifier: String?, rate: SpeechRate) {
        spoken.append((text, languageIdentifier, rate))
    }
    func pause() -> Bool { true }
    func resume() -> Bool { true }
    func stop() { stopCount += 1 }
}

@MainActor
private final class RecordingAudioBackend: AudioDataBackend {
    var onEnd: ((SpeechPlaybackEnd) -> Void)?
    var failsToPlay = false
    private(set) var played: [Data] = []
    private(set) var rates: [Float] = []

    func play(_ data: Data, rate: Float) throws {
        if failsToPlay { throw SpeechAudioError.notAudio }
        played.append(data)
        rates.append(rate)
    }
    func pause() -> Bool { true }
    func resume() -> Bool { true }
    func stop() {}
}

private actor StubFetcher: SpeechAudioFetching {
    private let result: Result<Data, Error>
    private(set) var requestedURLs: [URL] = []

    init(_ result: Result<Data, Error>) { self.result = result }

    func audio(from url: URL) async throws -> Data {
        requestedURLs.append(url)
        return try result.get()
    }
}

/// 依次返回预设结果，用于模拟“第一个地址失败、第二个成功”。
private actor SequenceFetcher: SpeechAudioFetching {
    private var results: [Result<Data, Error>]
    private(set) var requestedURLs: [URL] = []

    init(_ results: [Result<Data, Error>]) { self.results = results }

    func audio(from url: URL) async throws -> Data {
        requestedURLs.append(url)
        return try results.removeFirst().get()
    }
}

/// 一直等待直到被取消，用于模拟持续加载。
private struct NeverFinishingFetcher: SpeechAudioFetching {
    func audio(from url: URL) async throws -> Data {
        try await Task.sleep(for: .seconds(30))
        return Data()
    }
}

private actor GatedFetcher: SpeechAudioFetching {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false

    func audio(from url: URL) async throws -> Data {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return Data("late".utf8)
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// 不出声的播放器与合成器：保留真实的委托回调路径，只跳过实际发声。
private final class SilentAudioPlayer: AVAudioPlayer {
    override func play() -> Bool { true }
    override func stop() {}
}

private final class SilentSynthesizer: AVSpeechSynthesizer {
    private(set) var utterances: [AVSpeechUtterance] = []
    override func speak(_ utterance: AVSpeechUtterance) { utterances.append(utterance) }
    override func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }
}

/// 0.1 秒静音的 16 位单声道 WAV，供 AVAudioPlayer 解析。
private func silentWAV() -> Data {
    let sampleRate: UInt32 = 8_000
    let samples = Data(count: Int(sampleRate) / 10 * 2)
    func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    var data = Data("RIFF".utf8) + le(UInt32(36 + samples.count)) + Data("WAVEfmt ".utf8)
    data += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(sampleRate) + le(sampleRate * 2)
    data += le(UInt16(2)) + le(UInt16(16)) + Data("data".utf8) + le(UInt32(samples.count)) + samples
    return data
}

@MainActor
final class OnlineSpeechTests: XCTestCase {
    private let audio = Data("mp3".utf8)

    private func makeController(
        engine: SpeechEngineID,
        fetcher: SpeechAudioFetching,
        logger: DiagnosticLogging = NoopDiagnosticLogger()
    ) throws -> (SpeechController, RecordingSystemBackend, RecordingAudioBackend, UserDefaults, String) {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        let settings = SettingsStore(defaults: defaults)
        settings.speechEngine = engine
        let system = RecordingSystemBackend()
        let player = RecordingAudioBackend()
        let controller = SpeechController(
            settings: settings,
            fetcher: fetcher,
            logger: logger,
            systemBackend: system,
            audioBackend: player,
            systemVoiceLanguages: { LanguageCatalog.all.compactMap(\.speechLocale) }
        )
        return (controller, system, player, defaults, suite)
    }

    private func waitWhileLoading(_ controller: SpeechController) async throws {
        for _ in 0..<100 where controller.state == .loading {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - URL 与路由

    private func firstURL(
        _ engine: SpeechEngineID, _ text: String, _ language: String,
        accent: SpeechEnglishAccent = .us, rate: SpeechRate = .normal
    ) throws -> String {
        try XCTUnwrap(OnlineSpeechURLBuilder.attempts(
            engine: engine, text: text, language: language, accent: accent, rate: rate
        ).first).url.absoluteString
    }

    private func queryItems(_ url: URL) throws -> [String: String] {
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testYoudaoTriesSignedSentenceEndpointThenDictionaryEndpoint() throws {
        let attempts = OnlineSpeechURLBuilder.attempts(
            engine: .youdao, text: "tomato", language: "en", accent: .uk, rate: .normal
        )
        XCTAssertEqual(attempts.map(\.label), ["pronounce", "dictvoice"])
        XCTAssertTrue(attempts[0].url.absoluteString.hasPrefix("https://dict.youdao.com/pronounce/base?"))
        XCTAssertEqual(attempts[1].url.absoluteString, "https://dict.youdao.com/dictvoice?audio=tomato&le=en&type=1")

        let french = OnlineSpeechURLBuilder.attempts(
            engine: .youdao, text: "Bonjour", language: "fr", accent: .us, rate: .normal
        )
        XCTAssertEqual(french.map(\.label), ["pronounce"], "词典接口不支持法语，只保留整句接口")
    }

    func testYoudaoSignatureMatchesWebAlgorithm() throws {
        let now = Date(timeIntervalSince1970: 1_792_764_000.123)
        let url = try XCTUnwrap(OnlineSpeechURLBuilder.youdaoPronounceURL(
            text: "The cat + you & me", le: "en", voiceType: 1, now: now
        ))
        let query = try queryItems(url)
        XCTAssertEqual(query["word"], "The cat + you & me", "查询值须正确编码后可还原")
        XCTAssertEqual(query["mysticTime"], "1792764000123")
        XCTAssertEqual(query["type"], "1")

        let signedKeys = try XCTUnwrap(query["pointParam"]).split(separator: ",").map(String.init)
        XCTAssertEqual(signedKeys.last, "key")
        XCTAssertEqual(Array(signedKeys.dropLast()), Array(signedKeys.dropLast()).sorted())
        let raw = signedKeys.dropLast().map { "\($0)=\(query[$0] ?? "")" }.joined(separator: "&") + "&key=qCG2vdP92hOXDcKa"
        let expected = Insecure.MD5.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(query["sign"], expected)
    }

    func testURLsUseVerifiedCodesAccentsAndRates() throws {
        XCTAssertTrue(try firstURL(.youdao, "你好", "zh-Hans", accent: .uk).contains("le=zh"))
        XCTAssertTrue(try firstURL(.youdao, "你好", "zh-Hant").contains("le=zh"))

        XCTAssertTrue(try firstURL(.baidu, "a", "ja").contains("lan=jp&spd=3"))
        XCTAssertTrue(try firstURL(.baidu, "a", "zh-Hans", rate: .slow).contains("lan=zh&spd=3"))
        XCTAssertTrue(try firstURL(.baidu, "a", "en", accent: .uk, rate: .fast).contains("lan=uk&spd=5"))

        XCTAssertTrue(try firstURL(.google, "a", "en", accent: .uk).contains("tl=en-GB"))
        XCTAssertTrue(try firstURL(.google, "a", "zh-Hant").contains("tl=zh-TW"))
    }

    func testPlaybackRateIsLocalForYoudaoAndGoogleButServerSideForBaidu() {
        XCTAssertEqual(OnlineSpeechURLBuilder.playbackRate(engine: .youdao, rate: .fast), 1.25)
        XCTAssertEqual(OnlineSpeechURLBuilder.playbackRate(engine: .google, rate: .slow), 0.75)
        XCTAssertEqual(OnlineSpeechURLBuilder.playbackRate(engine: .youdao, rate: .normal), 1)
        XCTAssertEqual(OnlineSpeechURLBuilder.playbackRate(engine: .baidu, rate: .fast), 1, "百度语速由服务端合成")
    }

    func testURLsEncodeReservedCharactersAndRejectUnsupportedLanguages() throws {
        XCTAssertTrue(try firstURL(.google, "a+b&c=d", "en").contains("q=a%2Bb%26c%3Dd&"))
        XCTAssertTrue(OnlineSpeechURLBuilder.attempts(
            engine: .baidu, text: "Guten Tag", language: "de", accent: .us, rate: .normal
        ).isEmpty)
        XCTAssertTrue(OnlineSpeechURLBuilder.attempts(
            engine: .system, text: "a", language: "en", accent: .us, rate: .normal
        ).isEmpty)
    }

    func testRoutingFallsBackForSystemUnsupportedUnknownAndTooLongText() {
        XCTAssertNil(SpeechRoutingPolicy.onlineEngine(selected: .system, text: "hi", language: "en"))
        XCTAssertNil(SpeechRoutingPolicy.onlineEngine(selected: .baidu, text: "Salut", language: "fr"))
        XCTAssertNil(SpeechRoutingPolicy.onlineEngine(selected: .google, text: "hi", language: nil))
        XCTAssertNil(SpeechRoutingPolicy.onlineEngine(
            selected: .google, text: String(repeating: "a", count: 201), language: "en"
        ))
        XCTAssertEqual(
            SpeechRoutingPolicy.onlineEngine(selected: .google, text: String(repeating: "a", count: 200), language: "en"),
            .google
        )
    }

    func testLanguageNameUsesDeclaredLanguageAndDetection() {
        XCTAssertEqual(SpeechLanguageResolver.languageName(for: "tomato", declaredLanguage: "en-GB"), "en")
        XCTAssertEqual(SpeechLanguageResolver.languageName(for: "x", declaredLanguage: "ja"), "ja")
        XCTAssertEqual(
            SpeechLanguageResolver.languageName(for: "Bonjour tout le monde, comment allez-vous aujourd'hui ?", declaredLanguage: nil),
            "fr"
        )
        XCTAssertEqual(SpeechLanguageResolver.explicitAccent(declaredLanguage: "en-GB"), .uk)
        XCTAssertNil(SpeechLanguageResolver.explicitAccent(declaredLanguage: "en"))
    }

    // MARK: - 播放与兜底

    func testOnlinePlaybackLoadsThenPlaysWithDictionaryAccentOverridingSetting() async throws {
        let fetcher = StubFetcher(.success(audio))
        let (controller, system, player, defaults, suite) = try makeController(engine: .youdao, fetcher: fetcher)
        defer { defaults.removePersistentDomain(forName: suite) }

        controller.toggle(content: .dictionaryUK, text: "tomato", declaredLanguage: "en-GB")
        XCTAssertEqual(controller.state, .loading)
        XCTAssertEqual(controller.appearance(for: .dictionaryUK), .idle, "加载 300 毫秒内不显示加载状态")
        try await waitWhileLoading(controller)

        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(player.played, [audio])
        XCTAssertTrue(system.spoken.isEmpty)
        let requested = await fetcher.requestedURLs
        XCTAssertEqual(requested.count, 1)
        XCTAssertTrue(requested[0].absoluteString.contains("type=1"), "英式发音按钮应覆盖默认美式设置")
    }

    func testNetworkFailureFallsBackToSystemAndLogsOnlyCategory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = FileDiagnosticLogger(directory: directory)
        let (controller, system, player, defaults, suite) = try makeController(
            engine: .google,
            fetcher: StubFetcher(.failure(SpeechAudioError.http(500))),
            logger: logger
        )
        defer { defaults.removePersistentDomain(forName: suite) }

        controller.toggle(content: .source, text: "secret phrase", declaredLanguage: "en")
        try await waitWhileLoading(controller)

        XCTAssertEqual(controller.state, .speaking)
        XCTAssertTrue(player.played.isEmpty)
        XCTAssertEqual(system.spoken.map(\.text), ["secret phrase"])

        var log = ""
        for _ in 0..<50 where !log.contains("speech_fallback") {
            try await Task.sleep(for: .milliseconds(10))
            log = await logger.contents()
        }
        XCTAssertTrue(log.contains("speech_fallback"))
        XCTAssertTrue(log.contains("reason=http"))
        XCTAssertTrue(log.contains("host=translate.google.com"))
        XCTAssertFalse(log.contains("secret"), "诊断日志不得记录朗读文字")
    }

    func testPlaybackFailureFallsBackToSystem() async throws {
        let (controller, system, player, defaults, suite) = try makeController(
            engine: .youdao, fetcher: StubFetcher(.success(audio))
        )
        defer { defaults.removePersistentDomain(forName: suite) }
        player.failsToPlay = true

        controller.toggle(content: .source, text: "hello", declaredLanguage: "en")
        try await waitWhileLoading(controller)

        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(system.spoken.map(\.text), ["hello"])
    }

    func testUnsupportedSelectedEngineUsesSupportingOnlineEngine() async throws {
        let fetcher = StubFetcher(.success(audio))
        let (controller, system, _, defaults, suite) = try makeController(engine: .baidu, fetcher: fetcher)
        defer { defaults.removePersistentDomain(forName: suite) }

        controller.toggle(content: .translation(.google), text: "Guten Tag", declaredLanguage: "de")

        try await waitWhileLoading(controller)
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertTrue(system.spoken.isEmpty)
        let requested = await fetcher.requestedURLs
        XCTAssertEqual(requested.first?.host, "translate.google.com")
    }

    func testTappingWhileLoadingCancelsAndLateAudioIsIgnored() async throws {
        let fetcher = GatedFetcher()
        let (controller, system, player, defaults, suite) = try makeController(engine: .youdao, fetcher: fetcher)
        defer { defaults.removePersistentDomain(forName: suite) }

        controller.toggle(content: .source, text: "hello", declaredLanguage: "en")
        for _ in 0..<100 { if await fetcher.started { break }; await Task.yield() }
        controller.toggle(content: .source, text: "hello", declaredLanguage: "en")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.isActive(.source))

        await fetcher.release()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(player.played.isEmpty)
        XCTAssertTrue(system.spoken.isEmpty)
    }

    func testRepeatedPlaybackUsesCachedAudio() async throws {
        let fetcher = StubFetcher(.success(audio))
        let (controller, _, player, defaults, suite) = try makeController(engine: .youdao, fetcher: fetcher)
        defer { defaults.removePersistentDomain(forName: suite) }

        controller.toggle(content: .source, text: "hello", declaredLanguage: "en")
        try await waitWhileLoading(controller)
        player.onEnd?(.finished)
        XCTAssertEqual(controller.state, .idle)

        controller.toggle(content: .source, text: "hello", declaredLanguage: "en")
        XCTAssertEqual(controller.state, .speaking, "命中缓存时不经过加载状态")
        XCTAssertEqual(player.played.count, 2)
        let requested = await fetcher.requestedURLs
        XCTAssertEqual(requested.count, 1)
    }

    func testFinishCallbackFromReplacedPlaybackIsIgnored() throws {
        let (controller, system, _, defaults, suite) = try makeController(
            engine: .system, fetcher: StubFetcher(.success(audio))
        )
        defer { defaults.removePersistentDomain(forName: suite) }

        controller.toggle(content: .source, text: "first", declaredLanguage: "en")
        let staleFinish = system.onEnd
        controller.toggle(content: .translation(.google), text: "second", declaredLanguage: "en")
        staleFinish?(.finished)

        XCTAssertEqual(controller.state, .speaking)
        XCTAssertTrue(controller.isActive(.translation(.google)))
        system.onEnd?(.finished)
        XCTAssertEqual(controller.state, .idle)
    }

    func testAudioBackendIgnoresLateCallbackFromReplacedPlayerAndReportsFailure() async throws {
        var players: [AVAudioPlayer] = []
        let backend = AVAudioDataBackend { data in
            let player = try SilentAudioPlayer(data: data)
            players.append(player)
            return player
        }
        var ends: [SpeechPlaybackEnd] = []
        backend.onEnd = { ends.append($0) }

        try backend.play(silentWAV(), rate: 1)
        try backend.play(silentWAV(), rate: 1)
        XCTAssertEqual(players.count, 2)

        backend.audioPlayerDidFinishPlaying(players[0], successfully: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(ends.isEmpty, "被替换的播放器迟到的回调不得结束当前播放")

        backend.audioPlayerDidFinishPlaying(players[1], successfully: false)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(ends, [.failed])

        backend.audioPlayerDecodeErrorDidOccur(players[1], error: nil)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(ends, [.failed], "已结束的播放器不再重复通知")
    }

    func testSystemBackendIgnoresLateCallbackFromInterruptedUtterance() async throws {
        let synthesizer = SilentSynthesizer()
        let backend = AVSystemSpeechBackend(synthesizer: synthesizer)
        var ends: [SpeechPlaybackEnd] = []
        backend.onEnd = { ends.append($0) }

        backend.speak("first", languageIdentifier: "en-US", rate: .normal)
        backend.speak("second", languageIdentifier: "en-US", rate: .normal)
        let first = synthesizer.utterances[0]
        let second = synthesizer.utterances[1]

        backend.speechSynthesizer(synthesizer, didCancel: first)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(ends.isEmpty, "被打断的旧句子迟到的回调不得结束当前播放")

        backend.speechSynthesizer(synthesizer, didFinish: second)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(ends, [.finished])

        backend.speak("third", languageIdentifier: "en-US", rate: .normal)
        backend.stop()
        backend.speechSynthesizer(synthesizer, didCancel: synthesizer.utterances[2])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(ends, [.finished], "stop() 之后的取消回调被忽略")
    }

    func testFailureDuringOnlinePlaybackFallsBackToSystem() async throws {
        let (controller, system, player, defaults, suite) = try makeController(
            engine: .youdao, fetcher: StubFetcher(.success(audio))
        )
        defer { defaults.removePersistentDomain(forName: suite) }

        controller.toggle(content: .source, text: "hello", declaredLanguage: "en")
        try await waitWhileLoading(controller)
        XCTAssertEqual(player.played.count, 1)

        player.onEnd?(.failed)

        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(system.spoken.map(\.text), ["hello"])
    }

    func testYoudaoFallsBackToDictionaryEndpointWhenSignedEndpointFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = FileDiagnosticLogger(directory: directory)
        let fetcher = SequenceFetcher([.failure(SpeechAudioError.http(400)), .success(audio)])
        let (controller, system, player, defaults, suite) = try makeController(
            engine: .youdao, fetcher: fetcher, logger: logger
        )
        defer { defaults.removePersistentDomain(forName: suite) }

        controller.toggle(content: .dictionaryUS, text: "tomato", declaredLanguage: "en-US")
        try await waitWhileLoading(controller)

        XCTAssertEqual(player.played, [audio])
        XCTAssertTrue(system.spoken.isEmpty)
        let requested = await fetcher.requestedURLs
        XCTAssertEqual(requested.map(\.path), ["/pronounce/base", "/dictvoice"])

        var log = ""
        for _ in 0..<50 where !log.contains("speech_online_played") {
            try await Task.sleep(for: .milliseconds(10))
            log = await logger.contents()
        }
        XCTAssertTrue(log.contains("speech_attempt_failed endpoint=pronounce engine=youdao host=dict.youdao.com reason=http"))
        XCTAssertTrue(log.contains("endpoint=dictvoice"))
        XCTAssertFalse(log.contains("tomato"), "诊断日志不得记录朗读文字")
    }

    func testOnlinePlaybackUsesConfiguredLocalRate() async throws {
        let (controller, _, player, defaults, suite) = try makeController(
            engine: .google, fetcher: StubFetcher(.success(audio))
        )
        defer { defaults.removePersistentDomain(forName: suite) }
        controller.setRate(.fast, for: .google)

        controller.toggle(content: .source, text: "hello", declaredLanguage: "en")
        try await waitWhileLoading(controller)

        XCTAssertEqual(player.rates, [1.25])
    }

    func testShortContentRestartsWhileLongContentPausesAndResumes() throws {
        let (controller, system, _, defaults, suite) = try makeController(
            engine: .system, fetcher: StubFetcher(.success(audio))
        )
        defer { defaults.removePersistentDomain(forName: suite) }

        controller.toggle(content: .translation(.youdao), text: "give up", declaredLanguage: "en")
        XCTAssertEqual(controller.appearance(for: .translation(.youdao)), .playingShort)
        XCTAssertEqual(controller.label(for: .translation(.youdao)), "重新朗读译文")
        controller.toggle(content: .translation(.youdao), text: "give up", declaredLanguage: "en")
        XCTAssertEqual(system.spoken.map(\.text), ["give up", "give up"], "短内容再点从头重读")
        XCTAssertEqual(controller.state, .speaking)

        let sentence = "The cat sat on the purple mat yesterday."
        controller.toggle(content: .source, text: sentence, declaredLanguage: "en")
        XCTAssertEqual(controller.appearance(for: .source), .playingLong)
        XCTAssertEqual(controller.label(for: .source), "暂停朗读原文")
        controller.toggle(content: .source, text: sentence, declaredLanguage: "en")
        XCTAssertEqual(controller.appearance(for: .source), .paused)
        controller.toggle(content: .source, text: sentence, declaredLanguage: "en")
        XCTAssertEqual(controller.appearance(for: .source), .playingLong)
        XCTAssertEqual(system.spoken.count, 3, "暂停与继续不重新开始")
    }

    func testLoadingIndicatorAppearsOnlyAfterDelay() async throws {
        let fetcher = GatedFetcher()
        let (controller, _, player, defaults, suite) = try makeController(engine: .youdao, fetcher: fetcher)
        defer { defaults.removePersistentDomain(forName: suite) }

        controller.toggle(content: .source, text: "hello", declaredLanguage: "en")
        XCTAssertEqual(controller.state, .loading)
        XCTAssertEqual(controller.appearance(for: .source), .idle)

        try await Task.sleep(for: .milliseconds(380))
        XCTAssertEqual(controller.appearance(for: .source), .loading)
        XCTAssertEqual(controller.label(for: .source), "正在加载原文朗读，点击取消")

        await fetcher.release()
        try await waitWhileLoading(controller)
        XCTAssertEqual(player.played.count, 1)
        XCTAssertEqual(controller.appearance(for: .source), .playingShort)
        XCTAssertFalse(controller.loadingIndicatorVisible)
    }

    func testSwitchingToAnotherLoadingCardWaitsAgainBeforeShowingSpinner() async throws {
        let (controller, _, _, defaults, suite) = try makeController(engine: .youdao, fetcher: NeverFinishingFetcher())
        defer { defaults.removePersistentDomain(forName: suite) }

        controller.toggle(content: .translation(.youdao), text: "hello", declaredLanguage: "en")
        try await Task.sleep(for: .milliseconds(380))
        XCTAssertEqual(controller.appearance(for: .translation(.youdao)), .loading)

        controller.toggle(content: .translation(.google), text: "bonjour", declaredLanguage: "fr")
        XCTAssertEqual(controller.state, .loading)
        XCTAssertEqual(controller.appearance(for: .translation(.google)), .idle, "新卡片应重新等待 300 毫秒")
        try await Task.sleep(for: .milliseconds(380))
        XCTAssertEqual(controller.appearance(for: .translation(.google)), .loading)
        controller.stop()
    }

    func testSystemRateSettingIsApplied() throws {
        let (controller, system, _, defaults, suite) = try makeController(
            engine: .system, fetcher: StubFetcher(.success(audio))
        )
        defer { defaults.removePersistentDomain(forName: suite) }
        controller.setRate(.slow, for: .system)

        controller.toggle(content: .source, text: "hello", declaredLanguage: "en")

        XCTAssertEqual(system.spoken.first?.rate, .slow)
    }

    // MARK: - 联网检查（默认跳过）

    func testLiveEnginesReturnAudioForWordsAndSentences() async throws {
        guard ProcessInfo.processInfo.environment["SEVEN_LIVE_SPEECH_TESTS"] == "1" else {
            throw XCTSkip("Set SEVEN_LIVE_SPEECH_TESTS=1 to run online speech checks.")
        }
        let words = [
            "zh-Hans": "你好", "zh-Hant": "你好", "en": "hello", "ja": "こんにちは",
            "ko": "안녕하세요", "fr": "bonjour", "de": "hallo", "es": "hola", "ru": "привет"
        ]
        // 整句不在词典中，用来发现“只收录词条”的接口。
        let sentences = [
            "zh-Hans": "我们明天去公园散步，好不好？", "zh-Hant": "我們明天去公園散步，好不好？",
            "en": "The cat sat on the purple mat yesterday.", "ja": "明日は公園を散歩しましょう。",
            "ko": "내일 공원에서 산책할까요?", "fr": "Nous irons au parc demain matin.",
            "de": "Wir gehen morgen in den Park.", "es": "Mañana vamos al parque juntos.",
            "ru": "Завтра мы пойдём гулять в парк."
        ]
        let fetcher = URLSessionSpeechAudioFetcher()
        for engine in SpeechEngineCatalog.all where engine.isOnline {
            for language in engine.supportedLanguages where words[language] != nil {
                for text in [try XCTUnwrap(words[language]), try XCTUnwrap(sentences[language])] {
                    // 只测首选地址：有道签名常量失效时应在这里失败，而不是被词典接口掩盖。
                    let attempt = try XCTUnwrap(OnlineSpeechURLBuilder.attempts(
                        engine: engine.id, text: text, language: language, accent: .us, rate: .normal
                    ).first)
                    let data = try await fetcher.audio(from: attempt.url)
                    XCTAssertFalse(data.isEmpty, "\(engine.id) \(language) \(attempt.label)")
                }
            }
        }
    }
}
