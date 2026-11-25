import AVFoundation
import Foundation

/// 朗读按钮的身份。各翻译服务卡片分别带上服务标识，避免一张卡片播放时其他卡片也显示为播放中。
enum SpeechContent: Hashable {
    case source
    case translation(TranslationProviderID)
    case appleTranslation
    case dictionary
    case dictionaryUS
    case dictionaryUK
    case history(recordID: UUID, provider: TranslationProviderID?)

    /// 某个翻译服务卡片上朗读按钮对应的身份。
    static func result(of provider: TranslationProviderID) -> SpeechContent {
        switch provider {
        case .ecdict: return .dictionary
        case .appleTranslation: return .appleTranslation
        default: return .translation(provider)
        }
    }
}

enum SpeechPlaybackState: Equatable {
    case idle
    /// 正在下载在线朗读音频；再次点击同一内容会取消。
    case loading
    case speaking
    case paused
}

enum SpeechPlaybackDecision: Equatable {
    case start
    case pause
    case resume
    case cancel
    /// 短内容播放中再次点击：从头重读。
    case restart
}

/// 朗读按钮的外观，由播放状态与内容长短共同决定。
enum SpeechButtonAppearance: Equatable {
    case idle
    /// 下载超过 300 毫秒仍未开始播放时才显示，避免一闪而过。
    case loading
    /// 单词、短语：播放时显示动态喇叭，再点从头重读。
    case playingShort
    /// 句子、段落：播放时显示暂停，再点暂停。
    case playingLong
    case paused
}

/// 能被词典收录的长度视为短内容：非中日韩文字不超过 4 个词且不超过 80 字符；中日韩文字不超过 6 个字。
enum SpeechLengthPolicy {
    static let maximumShortCJKCharacters = 6
    static let maximumShortWords = 4

    static func isShort(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isNewline) else { return false }
        if value.unicodeScalars.contains(where: isCJK) {
            let characters = value.filter { !$0.isWhitespace && !$0.isPunctuation }
            return characters.count <= maximumShortCJKCharacters
        }
        guard value.count <= 80 else { return false }
        return value.split(whereSeparator: \.isWhitespace).count <= maximumShortWords
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: return true
        default: return false
        }
    }
}

enum SpeechPlaybackPolicy {
    static func decision(
        state: SpeechPlaybackState,
        activeContent: SpeechContent?,
        requestedContent: SpeechContent,
        activeIsShort: Bool = false
    ) -> SpeechPlaybackDecision {
        guard activeContent == requestedContent else { return .start }
        switch state {
        case .idle: return .start
        case .loading: return .cancel
        case .speaking: return activeIsShort ? .restart : .pause
        case .paused: return .resume
        }
    }
}

enum SpeechLanguageResolver {
    /// 词典的美式、英式发音按钮使用的标识。
    static let englishUS = "en-US"
    static let englishUK = "en-GB"

    /// 把朗读文字归到Seven支持的语言代码，供在线服务判断是否支持；无法判断时返回 nil。
    static func languageName(for text: String, declaredLanguage: String?, primary: String = LanguageCatalog.defaultPrimary, secondary: String = LanguageCatalog.defaultSecondary) -> String? {
        if let declaredLanguage {
            if declaredLanguage == englishUS || declaredLanguage == englishUK { return "en" }
            if LanguageCatalog.language(declaredLanguage) != nil { return declaredLanguage }
        }
        return LanguageCatalog.detectedCode(for: text, primary: primary, secondary: secondary)
    }

    /// 词典的美式、英式发音按钮自带口音，优先于设置。
    static func explicitAccent(declaredLanguage: String?) -> SpeechEnglishAccent? {
        switch declaredLanguage {
        case englishUS: return .us
        case englishUK: return .uk
        default: return nil
        }
    }
}

enum SpeechPlaybackEnd: Equatable {
    case finished
    case failed
}

@MainActor
protocol SpeechPlaybackBackend: AnyObject {
    /// 当前这次播放结束时调用；已被 stop() 或新播放替换的旧播放不会触发。
    var onEnd: ((SpeechPlaybackEnd) -> Void)? { get set }
    func pause() -> Bool
    func resume() -> Bool
    func stop()
}

@MainActor
protocol SystemSpeechBackend: SpeechPlaybackBackend {
    func speak(_ text: String, languageIdentifier: String?, rate: SpeechRate)
}

@MainActor
protocol AudioDataBackend: SpeechPlaybackBackend {
    /// `rate` 为倍速（1 为原速），播放时保持音调。
    func play(_ data: Data, rate: Float) throws
}

struct SpeechAudioCacheKey: Hashable {
    let engine: SpeechEngineID
    let text: String
    let language: String
    let accent: SpeechEnglishAccent
    let serverRate: SpeechRate?
}

@MainActor
final class SpeechController: NSObject, ObservableObject {
    @Published private(set) var state: SpeechPlaybackState = .idle {
        didSet { if state != .loading, loadingIndicatorVisible { loadingIndicatorVisible = false } }
    }
    @Published private(set) var activeContent: SpeechContent?
    @Published private(set) var engineID: SpeechEngineID
    @Published private(set) var loadingIndicatorVisible = false
    private var activeIsShort = false
    private static let loadingIndicatorDelay: Duration = .milliseconds(300)

    private let systemVoiceLanguages: () -> [String]
    private let settings: SettingsStore
    private let fetcher: SpeechAudioFetching
    private let logger: DiagnosticLogging
    private let systemBackend: SystemSpeechBackend
    private let audioBackend: AudioDataBackend
    private var activeBackend: SpeechPlaybackBackend?
    private var playbackID = UUID()
    private var loadTask: Task<Void, Never>?
    private var audioCache: [SpeechAudioCacheKey: Data] = [:]
    private var audioCacheOrder: [SpeechAudioCacheKey] = []
    private static let audioCacheLimit = 20

    init(
        settings: SettingsStore = SettingsStore(),
        fetcher: SpeechAudioFetching = URLSessionSpeechAudioFetcher(),
        logger: DiagnosticLogging = NoopDiagnosticLogger(),
        systemBackend: SystemSpeechBackend? = nil,
        audioBackend: AudioDataBackend? = nil,
        systemVoiceLanguages: @escaping () -> [String] = { SystemSpeechAvailability.installedLanguages }
    ) {
        self.systemVoiceLanguages = systemVoiceLanguages
        self.settings = settings
        self.fetcher = fetcher
        self.logger = logger
        self.systemBackend = systemBackend ?? AVSystemSpeechBackend()
        self.audioBackend = audioBackend ?? AVAudioDataBackend()
        engineID = settings.speechEngine
        super.init()
    }

    func selectEngine(_ id: SpeechEngineID) {
        guard id != engineID else { return }
        stop()
        settings.speechEngine = id
        engineID = id
    }

    func englishAccent(for engine: SpeechEngineID) -> SpeechEnglishAccent {
        settings.speechEnglishAccent(for: engine)
    }

    func setEnglishAccent(_ accent: SpeechEnglishAccent, for engine: SpeechEngineID) {
        settings.setSpeechEnglishAccent(accent, for: engine)
        objectWillChange.send()
    }

    func rate(for engine: SpeechEngineID) -> SpeechRate {
        settings.speechRate(for: engine)
    }

    func setRate(_ rate: SpeechRate, for engine: SpeechEngineID) {
        settings.setSpeechRate(rate, for: engine)
        objectWillChange.send()
    }

    func toggle(content: SpeechContent, text: String, declaredLanguage: String?) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        switch SpeechPlaybackPolicy.decision(
            state: state,
            activeContent: activeContent,
            requestedContent: content,
            activeIsShort: activeIsShort
        ) {
        case .start, .restart:
            start(content: content, text: normalized, declaredLanguage: declaredLanguage)
        case .pause:
            if activeBackend?.pause() == true { state = .paused }
        case .resume:
            if activeBackend?.resume() == true { state = .speaking }
        case .cancel:
            stop()
        }
    }

    func stop() {
        guard state != .idle else { return }
        haltPlayback()
        finishPlayback()
    }

    func stopHistoryPlayback() {
        guard case .history? = activeContent else { return }
        stop()
    }

    func isActive(_ content: SpeechContent) -> Bool {
        activeContent == content && state != .idle
    }

    func appearance(for content: SpeechContent) -> SpeechButtonAppearance {
        guard activeContent == content else { return .idle }
        switch state {
        case .idle: return .idle
        case .loading: return loadingIndicatorVisible ? .loading : .idle
        case .speaking: return activeIsShort ? .playingShort : .playingLong
        case .paused: return .paused
        }
    }

    /// 静态图标；加载转圈与喇叭的逐帧动画由按钮自行绘制（见 SpeechToggleButton）。
    func icon(for content: SpeechContent) -> String {
        switch appearance(for: content) {
        case .idle, .loading: return "speaker.wave.2"
        case .playingShort: return "speaker.wave.2"
        case .playingLong: return "pause.fill"
        case .paused: return "play.fill"
        }
    }

    func label(for content: SpeechContent) -> String {
        let noun: String
        switch content {
        case .source: noun = L10n.text("sourceText")
        case .translation: noun = L10n.text("translation")
        case .appleTranslation: noun = L10n.text("appleTranslationResult")
        case .dictionary: noun = L10n.text("definitions")
        case .dictionaryUS: noun = L10n.text("usPronunciation")
        case .dictionaryUK: noun = L10n.text("ukPronunciation")
        case .history(_, let provider):
            noun = L10n.text(provider == nil ? "sourceText" : provider == .ecdict ? "definitions" : "translation")
        }
        switch appearance(for: content) {
        case .idle: return L10n.format("readAloud", String(describing: noun))
        case .loading: return L10n.format("loadingAudioForClickToCancel", String(describing: noun))
        case .playingShort: return L10n.format("readAgain", String(describing: noun))
        case .playingLong: return L10n.format("pause", String(describing: noun))
        case .paused: return L10n.format("resume", String(describing: noun))
        }
    }

    private func route(text: String, declaredLanguage: String?, excluding: Set<SpeechEngineID> = []) -> SpeechEngineID? {
        guard let language = SpeechLanguageResolver.languageName(for: text, declaredLanguage: declaredLanguage, primary: settings.primaryLanguage, secondary: settings.secondaryLanguage) else { return nil }
        let order: [SpeechEngineID] = excluding.isEmpty ? [engineID, .google, .youdao, .baidu, .system] : [.system, .google, .youdao, .baidu]
        for candidate in order where !excluding.contains(candidate) {
            if candidate == .system {
                if SystemSpeechAvailability.voiceLanguage(for: language, installed: systemVoiceLanguages()) != nil { return .system }
            } else if SpeechRoutingPolicy.onlineEngine(selected: candidate, text: text, language: language) != nil {
                return candidate
            }
        }
        return nil
    }

    func canSpeak(text: String, declaredLanguage: String?) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && route(text: normalized, declaredLanguage: declaredLanguage) != nil
    }

    func availabilityLabel(content: SpeechContent, text: String, declaredLanguage: String?) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return label(for: content) }
        guard !canSpeak(text: text, declaredLanguage: declaredLanguage) else { return label(for: content) }
        let language = SpeechLanguageResolver.languageName(for: text, declaredLanguage: declaredLanguage, primary: settings.primaryLanguage, secondary: settings.secondaryLanguage)
        if let language, route(text: "x", declaredLanguage: language) != nil { return L10n.text("thisTextExceedsTheCharacterLimitOf") }
        return language.map { L10n.format("speechIsUnavailableFor", String(describing: LanguageCatalog.name($0))) } ?? L10n.text("couldNotDetermineTheSpeechLanguage")
    }

    // MARK: - Playback

    private func start(content: SpeechContent, text: String, declaredLanguage: String?, excluding: Set<SpeechEngineID> = []) {
        haltPlayback()
        let id = UUID()
        playbackID = id
        activeContent = content
        activeIsShort = SpeechLengthPolicy.isShort(text)
        // 新的一次朗读重新等待 300 毫秒再显示转圈，不沿用上一次已显示的转圈。
        loadingIndicatorVisible = false

        let language = SpeechLanguageResolver.languageName(for: text, declaredLanguage: declaredLanguage, primary: settings.primaryLanguage, secondary: settings.secondaryLanguage)
        guard let chosen = route(text: text, declaredLanguage: declaredLanguage, excluding: excluding), let language else {
            finishPlayback()
            return
        }
        if chosen == .system {
            speakWithSystem(text, declaredLanguage: declaredLanguage ?? language, playbackID: id, excluding: excluding.union([.system]))
            return
        }
        let online = chosen
        let accent = SpeechLanguageResolver.explicitAccent(declaredLanguage: declaredLanguage)
            ?? settings.speechEnglishAccent(for: online)
        let rate = settings.speechRate(for: online)
        let attempts = OnlineSpeechURLBuilder.attempts(
            engine: online, text: text, language: language, accent: accent, rate: rate
        )
        guard !attempts.isEmpty else {
            speakWithSystem(text, declaredLanguage: declaredLanguage, playbackID: id)
            return
        }
        let playback = OnlinePlayback(
            engine: online, text: text, declaredLanguage: declaredLanguage,
            playbackRate: OnlineSpeechURLBuilder.playbackRate(engine: online, rate: rate),
            excluded: excluding.union([online])
        )
        // 有道地址含时间戳签名，按内容而不是按地址缓存。百度语速在服务端合成，需计入缓存键。
        let cacheKey = SpeechAudioCacheKey(
            engine: online, text: text, language: language, accent: accent,
            serverRate: online == .baidu ? rate : nil
        )

        if let cached = audioCache[cacheKey] {
            playAudio(cached, playback, playbackID: id)
            return
        }

        state = .loading
        Task { [weak self] in
            try? await Task.sleep(for: Self.loadingIndicatorDelay)
            guard let self, self.playbackID == id, self.state == .loading else { return }
            self.loadingIndicatorVisible = true
        }
        let startedAt = Date()
        loadTask = Task { [weak self, fetcher] in
            var lastReason = "transport"
            for attempt in attempts {
                do {
                    let data = try await fetcher.audio(from: attempt.url)
                    guard let self, self.playbackID == id, !Task.isCancelled else { return }
                    self.cacheAudio(data, for: cacheKey)
                    self.record(.info, "speech_online_played", engine: online, extra: [
                        "endpoint": attempt.label,
                        "characters": String(text.count),
                        "elapsed_ms": String(Int(Date().timeIntervalSince(startedAt) * 1000))
                    ])
                    self.playAudio(data, playback, playbackID: id)
                    return
                } catch {
                    guard let self, self.playbackID == id, !Task.isCancelled, !(error is CancellationError) else { return }
                    lastReason = (error as? SpeechAudioError)?.diagnosticCategory ?? String(describing: type(of: error))
                    if attempt != attempts.last {
                        self.record(.warning, "speech_attempt_failed", engine: online, extra: [
                            "endpoint": attempt.label, "reason": lastReason
                        ])
                    }
                }
            }
            guard let self, self.playbackID == id, !Task.isCancelled else { return }
            self.record(.warning, "speech_fallback", engine: online, extra: [
                "endpoint": attempts.last?.label ?? "", "reason": lastReason
            ])
            self.start(content: content, text: text, declaredLanguage: declaredLanguage, excluding: playback.excluded)
        }
    }

    private struct OnlinePlayback {
        let engine: SpeechEngineID
        let text: String
        let declaredLanguage: String?
        let playbackRate: Float
        let excluded: Set<SpeechEngineID>
    }

    private func playAudio(_ data: Data, _ playback: OnlinePlayback, playbackID id: UUID) {
        let engine = playback.engine
        audioBackend.onEnd = { [weak self] end in
            guard let self, self.playbackID == id else { return }
            guard end == .failed else { return self.finishIfCurrent(id) }
            // 解码失败后只尝试确实支持此语言的替代服务。
            self.record(.warning, "speech_fallback", engine: engine, extra: ["reason": "playback"])
            self.fallbackAfterAudio(playback)
        }
        do {
            try audioBackend.play(data, rate: playback.playbackRate)
            activeBackend = audioBackend
            state = .speaking
        } catch {
            record(.warning, "speech_fallback", engine: engine, extra: ["reason": "playback"])
            fallbackAfterAudio(playback)
        }
    }

    private func fallbackAfterAudio(_ playback: OnlinePlayback) {
        guard let content = activeContent else { return }
        start(content: content, text: playback.text, declaredLanguage: playback.declaredLanguage, excluding: playback.excluded)
    }

    private func speakWithSystem(_ text: String, declaredLanguage: String?, playbackID id: UUID, excluding: Set<SpeechEngineID> = []) {
        guard let code = SpeechLanguageResolver.languageName(for: text, declaredLanguage: declaredLanguage, primary: settings.primaryLanguage, secondary: settings.secondaryLanguage),
              let matched = SystemSpeechAvailability.voiceLanguage(for: code, installed: systemVoiceLanguages()) else {
            finishPlayback()
            return
        }
        let explicitAccent = SpeechLanguageResolver.explicitAccent(declaredLanguage: declaredLanguage)
        let identifier = explicitAccent != nil && systemVoiceLanguages().contains(declaredLanguage ?? "")
            ? declaredLanguage : matched
        systemBackend.onEnd = { [weak self] end in
            guard let self, self.playbackID == id else { return }
            if end == .failed, let content = self.activeContent {
                // Voices can disappear after the runtime snapshot; try a verified online route instead.
                self.start(content: content, text: text, declaredLanguage: declaredLanguage, excluding: excluding.union([.system]))
            } else {
                self.finishIfCurrent(id)
            }
        }
        activeBackend = systemBackend
        state = .speaking
        systemBackend.speak(
            text,
            languageIdentifier: identifier,
            rate: settings.speechRate(for: .system)
        )
    }

    /// 停止正在进行的下载与播放，但不改动对外状态；旧播放的结束回调会因 playbackID 变化而被忽略。
    private func haltPlayback() {
        playbackID = UUID()
        loadTask?.cancel()
        loadTask = nil
        activeBackend?.stop()
        activeBackend = nil
    }

    private func finishIfCurrent(_ id: UUID) {
        guard playbackID == id else { return }
        activeBackend = nil
        finishPlayback()
    }

    private func finishPlayback() {
        state = .idle
        activeContent = nil
    }

    private func cacheAudio(_ data: Data, for key: SpeechAudioCacheKey) {
        if audioCache[key] == nil { audioCacheOrder.append(key) }
        audioCache[key] = data
        while audioCacheOrder.count > Self.audioCacheLimit {
            audioCache[audioCacheOrder.removeFirst()] = nil
        }
    }

    private func record(_ level: DiagnosticLevel, _ event: String, engine: SpeechEngineID, extra: [String: String]) {
        var metadata = extra
        metadata["engine"] = engine.rawValue
        metadata["host"] = SpeechEngineCatalog.descriptor(for: engine).host ?? ""
        Task { [logger] in await logger.record(level, event, metadata: metadata) }
    }
}

// MARK: - System backends

/// 仅用于在回调与主线程之间传递对象身份做比较，不访问其内容。
private struct ObjectReference<Object: AnyObject>: @unchecked Sendable {
    let object: Object
}

@MainActor
final class AVSystemSpeechBackend: NSObject, SystemSpeechBackend {
    var onEnd: ((SpeechPlaybackEnd) -> Void)?
    private let synthesizer: AVSpeechSynthesizer
    private var currentUtterance: AVSpeechUtterance?

    init(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, languageIdentifier: String?, rate: SpeechRate) {
        let utterance = AVSpeechUtterance(string: text)
        guard let languageIdentifier, let voice = AVSpeechSynthesisVoice(language: languageIdentifier) else {
            onEnd?(.failed)
            return
        }
        utterance.voice = voice
        switch rate {
        case .slow: utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.8
        case .normal: utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        case .fast: utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.2
        }
        currentUtterance = utterance
        synthesizer.speak(utterance)
    }

    func pause() -> Bool { synthesizer.pauseSpeaking(at: .word) }
    func resume() -> Bool { synthesizer.continueSpeaking() }

    func stop() {
        currentUtterance = nil
        _ = synthesizer.stopSpeaking(at: .immediate)
    }

    /// 只有当前这句话结束才通知；被打断的旧句子迟到的回调会被忽略。
    func utteranceEnded(_ utterance: AVSpeechUtterance) {
        guard let currentUtterance, currentUtterance === utterance else { return }
        self.currentUtterance = nil
        onEnd?(.finished)
    }
}

extension AVSystemSpeechBackend: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let reference = ObjectReference(object: utterance)
        Task { @MainActor [weak self] in self?.utteranceEnded(reference.object) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let reference = ObjectReference(object: utterance)
        Task { @MainActor [weak self] in self?.utteranceEnded(reference.object) }
    }
}

@MainActor
final class AVAudioDataBackend: NSObject, AudioDataBackend {
    var onEnd: ((SpeechPlaybackEnd) -> Void)?
    private let makePlayer: (Data) throws -> AVAudioPlayer
    private var player: AVAudioPlayer?

    init(makePlayer: @escaping (Data) throws -> AVAudioPlayer = { try AVAudioPlayer(data: $0) }) {
        self.makePlayer = makePlayer
        super.init()
    }

    func play(_ data: Data, rate: Float) throws {
        let player = try makePlayer(data)
        player.delegate = self
        if rate != 1 {
            player.enableRate = true
            player.rate = rate
        }
        self.player = player
        guard player.play() else {
            self.player = nil
            throw SpeechAudioError.notAudio
        }
    }

    func pause() -> Bool {
        guard let player, player.isPlaying else { return false }
        player.pause()
        return true
    }

    func resume() -> Bool { player?.play() ?? false }

    func stop() {
        player?.stop()
        player = nil
    }

    /// 只有当前播放器结束才通知；已停止或被替换的播放器迟到的回调会被忽略。
    func playerEnded(_ endedPlayer: AVAudioPlayer, end: SpeechPlaybackEnd) {
        guard let player, player === endedPlayer else { return }
        self.player = nil
        onEnd?(end)
    }
}

extension AVAudioDataBackend: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let reference = ObjectReference(object: player)
        Task { @MainActor [weak self] in self?.playerEnded(reference.object, end: flag ? .finished : .failed) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let reference = ObjectReference(object: player)
        Task { @MainActor [weak self] in self?.playerEnded(reference.object, end: .failed) }
    }
}
