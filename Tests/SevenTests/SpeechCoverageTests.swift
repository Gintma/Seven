import AVFoundation
import XCTest
@testable import Seven

final class SpeechCoverageTests: XCTestCase {
    static let samples = [
        "zh-Hans":"早上好，祝你今天愉快。", "zh-Hant":"早安，祝你今天愉快。", "en":"Good morning, have a lovely day.",
        "ja":"おはようございます。今日はいい天気です。", "ko":"안녕하세요. 좋은 하루 보내세요.",
        "fr":"Bonjour, passez une bonne journée.", "de":"Guten Morgen, einen schönen Tag.", "es":"Buenos días, que tengas un buen día.",
        "pt":"Bom dia, tenha um ótimo dia.", "it":"Buongiorno, buona giornata.", "ru":"Доброе утро, хорошего дня.",
        "nl":"Goedemorgen, een fijne dag.", "pl":"Dzień dobry, miłego dnia.", "sv":"God morgon, ha en trevlig dag.",
        "uk":"Доброго ранку, гарного дня.", "el":"Καλημέρα, να έχετε μια όμορφη μέρα.", "tr":"Günaydın, iyi günler.",
        "cs":"Dobré ráno, hezký den.", "vi":"Chào buổi sáng, chúc một ngày tốt lành.", "th":"สวัสดีตอนเช้า ขอให้มีความสุข", 
        "id":"Selamat pagi, semoga harimu menyenangkan.", "ms":"Selamat pagi, semoga hari anda baik.",
        "hi":"सुप्रभात, आपका दिन शुभ हो।", "ar":"صباح الخير، أتمنى لك يوماً سعيداً.", "fa":"صبح بخیر، روز خوبی داشته باشید.",
        "he":"בוקר טוב, שיהיה לך יום נעים.", "fil":"Magandang umaga, magandang araw sa iyo.",
        "bn":"সুপ্রভাত, আপনার দিনটি ভালো কাটুক।", "ur":"صبح بخیر، آپ کا دن اچھا گزرے۔", "sw":"Habari za asubuhi, uwe na siku njema."
    ]

    /// Discovery deliberately tries every catalog language, including candidates not yet approved for routing.
    /// HTTP/MIME success alone is insufficient: AVAudioPlayer must decode a nonzero duration.
    func testLiveSpeechCoverageDiscovery() async throws {
        guard ProcessInfo.processInfo.environment["SEVEN_LIVE_TRANSLATION_TESTS"] == "1" else {
            throw XCTSkip("Set SEVEN_LIVE_TRANSLATION_TESTS=1 to probe speech coverage.")
        }
        struct Probe: Codable, Sendable { let engine: String; let language: String; let playable: Bool; let bytes: Int; let duration: Double }
        var results: [Probe] = []
        for engine in [SpeechEngineID.youdao, .baidu, .google] {
            for batchStart in stride(from: 0, to: LanguageCatalog.all.count, by: 5) {
                let batch = Array(LanguageCatalog.all.dropFirst(batchStart).prefix(5))
                let values = await withTaskGroup(of: Probe.self, returning: [Probe].self) { group in
                    for language in batch {
                        group.addTask {
                            let code = language.code
                            let text = Self.samples[code] ?? "Good morning"
                            let url: URL?
                            if engine == .youdao {
                                url = OnlineSpeechURLBuilder.youdaoPronounceURL(text: text, le: ["zh-Hans":"zh", "zh-Hant":"zh", "fil":"tl", "he":"he" ][code] ?? code, voiceType: 2, now: Date())
                            } else {
                                let lan = engine == .google ? (language.googleCode ?? code) : (["zh-Hans":"zh", "zh-Hant":"zh", "ja":"jp", "ko":"kor", "fr":"fra", "es":"spa", "ar":"ara" ][code] ?? code)
                                var c = URLComponents(string: engine == .google ? "https://translate.google.com/translate_tts" : "https://fanyi.baidu.com/gettts")
                                c?.queryItems = (engine == .google ? [("ie","UTF-8"),("q",text),("tl",lan),("client","tw-ob")] : [("text",text),("lan",lan),("spd","3"),("source","web")]).map { URLQueryItem(name:$0.0,value:$0.1) }
                                url = engine == .baidu && code == "uk" ? nil : c?.url
                            }
                            do {
                                guard let url else { return Probe(engine:engine.rawValue,language:code,playable:false,bytes:0,duration:0) }
                                let data = try await URLSessionSpeechAudioFetcher().audio(from: url)
                                let player = try AVAudioPlayer(data:data)
                                return Probe(engine:engine.rawValue,language:code,playable:player.duration > 0,bytes:data.count,duration:player.duration)
                            } catch { return Probe(engine:engine.rawValue,language:code,playable:false,bytes:0,duration:0) }
                        }
                    }
                    var v:[Probe]=[];for await r in group { v.append(r) };return v
                }
                results += values
                print("Coverage",engine.rawValue,values.sorted{$0.language<$1.language}.map{"\($0.language):\($0.playable)"}.joined(separator:" "))
            }
        }
        try JSONEncoder().encode(results).write(to: URL(fileURLWithPath:"/tmp/seven-speech-coverage.json"))
        XCTAssertEqual(results.count,LanguageCatalog.all.count*3)
        for engine in [SpeechEngineID.youdao, .baidu, .google] {
            for language in SpeechEngineCatalog.descriptor(for: engine).supportedLanguages {
                XCTAssertEqual(results.first { $0.engine == engine.rawValue && $0.language == language }?.playable, true,
                    "Verified routing entry failed audio decoding: \(engine.rawValue) \(language)")
            }
        }
    }
}

@MainActor
private final class CoverageSystem: SystemSpeechBackend {
    var onEnd: ((SpeechPlaybackEnd) -> Void)?
    var languages: [String?] = []
    var fails = false
    func speak(_ text: String, languageIdentifier: String?, rate: SpeechRate) {
        languages.append(languageIdentifier)
        if fails { onEnd?(.failed) }
    }
    func pause() -> Bool { true }
    func resume() -> Bool { true }
    func stop() {}
}
@MainActor
private final class CoverageAudio: AudioDataBackend {
    var onEnd: ((SpeechPlaybackEnd) -> Void)?
    var plays = 0
    func play(_ data: Data, rate: Float) throws { plays += 1 }
    func pause() -> Bool { true }
    func resume() -> Bool { true }
    func stop() {}
}
private actor CoverageFetcher: SpeechAudioFetching {
    var hosts: [String] = []
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func audio(from url: URL) async throws -> Data {
        hosts.append(url.host ?? "")
        if fails { throw SpeechAudioError.transport }
        return Data([1])
    }
}
@MainActor
final class SpeechCoverageRoutingTests: XCTestCase {
    func testVoiceMatchingNeverUsesUnrelatedLanguage() {
        XCTAssertNil(SystemSpeechAvailability.voiceLanguage(for: "fa", installed: ["en-US", "ar-SA"]))
        XCTAssertEqual(SystemSpeechAvailability.voiceLanguage(for: "en", installed: ["en-GB"]), "en-GB")
        XCTAssertNil(SystemSpeechAvailability.voiceLanguage(for: "zh-Hant", installed: ["zh-CN"]))
    }

    func testMissingSystemVoiceUsesGoogleForFilipinoUrduAndSwahili() async throws {
        let suite = "SpeechCoverage-\(UUID())"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        for language in ["fil", "ur", "sw"] {
            let fetcher = CoverageFetcher(), system = CoverageSystem(), audio = CoverageAudio()
            let controller = SpeechController(settings:SettingsStore(defaults:defaults), fetcher:fetcher,
                systemBackend:system, audioBackend:audio, systemVoiceLanguages:{["en-US"]})
            XCTAssertTrue(controller.canSpeak(text:"test",declaredLanguage:language))
            controller.toggle(content:.source,text:SpeechCoverageTests.samples[language] ?? "test",declaredLanguage:language)
            for _ in 0..<100 where controller.state == .loading { try await Task.sleep(for:.milliseconds(5)) }
            XCTAssertEqual(audio.plays,1)
            XCTAssertTrue(system.languages.isEmpty)
            let hosts = await fetcher.hosts
            XCTAssertEqual(hosts,["translate.google.com"])
            controller.stop()
        }
    }

    func testRuntimeVoiceProviderCanEnablePreviouslyMissingLanguage() throws {
        let suite = "SpeechCoverage-\(UUID())"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        var installed = ["en-US"]
        let controller = SpeechController(settings:SettingsStore(defaults:defaults),systemBackend:CoverageSystem(),
            systemVoiceLanguages:{ installed })
        XCTAssertFalse(controller.canSpeak(text:"سلام",declaredLanguage:"fa"))
        installed.append("fa-IR")
        XCTAssertTrue(controller.canSpeak(text:"سلام",declaredLanguage:"fa"))
    }

    func testNoVoiceAndTextOverOnlineLimitIsDisabled() throws {
        let suite = "SpeechCoverage-\(UUID())"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let controller = SpeechController(settings:SettingsStore(defaults:defaults),systemBackend:CoverageSystem(),
            systemVoiceLanguages:{ [] })
        let text = String(repeating:"Habari ",count:100)
        XCTAssertFalse(controller.canSpeak(text:text,declaredLanguage:"sw"))
        XCTAssertTrue(controller.canSpeak(text: "x", declaredLanguage: "sw"))
        XCTAssertEqual(controller.availabilityLabel(content: .source, text: text, declaredLanguage: "sw"),
                       L10n.text("thisTextExceedsTheCharacterLimitOf"))
    }

    func testUncoveredPersianIsDisabledAndNeverSpeaksDefaultVoice() throws {
        let suite = "SpeechCoverage-\(UUID())"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let system = CoverageSystem()
        let controller = SpeechController(settings:SettingsStore(defaults:defaults),systemBackend:system,
            systemVoiceLanguages:{["en-US"]})
        XCTAssertFalse(controller.canSpeak(text:"سلام",declaredLanguage:"fa"))
        XCTAssertEqual(controller.availabilityLabel(content: .source, text: "", declaredLanguage: "fa"),
                       controller.label(for: .source))
        XCTAssertEqual(controller.availabilityLabel(content: .source, text: "سلام", declaredLanguage: "fa"),
                       L10n.format("speechIsUnavailableFor", LanguageCatalog.name("fa")))
        controller.toggle(content:.source,text:"سلام",declaredLanguage:"fa")
        XCTAssertEqual(controller.state,.idle)
        XCTAssertTrue(system.languages.isEmpty)
    }

    func testSystemAndOnlineFailuresTerminateWithoutFallbackLoop() async throws {
        let suite = "SpeechCoverage-\(UUID())"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let system = CoverageSystem(), fetcher = CoverageFetcher(fails:true)
        system.fails = true
        let controller = SpeechController(settings:SettingsStore(defaults:defaults),fetcher:fetcher,
            systemBackend:system, systemVoiceLanguages:{["en-US"]})
        controller.toggle(content:.source,text:"hello",declaredLanguage:"en")
        for _ in 0..<100 where controller.state == .loading { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertEqual(controller.state,.idle)
        XCTAssertEqual(system.languages.count,1)
        let hosts = await fetcher.hosts
        XCTAssertLessThanOrEqual(hosts.count,4)
    }

    func testOnlineFailureWithoutSystemVoiceStopsInsteadOfWrongVoice() async throws {
        let suite = "SpeechCoverage-\(UUID())"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let system = CoverageSystem(), fetcher = CoverageFetcher(fails:true)
        let controller = SpeechController(settings:SettingsStore(defaults:defaults),fetcher:fetcher,
            systemBackend:system, systemVoiceLanguages:{["en-US"]})
        controller.toggle(content:.source,text:"Habari",declaredLanguage:"sw")
        for _ in 0..<100 where controller.state == .loading { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertEqual(controller.state,.idle)
        XCTAssertTrue(system.languages.isEmpty)
        let hosts = await fetcher.hosts
        XCTAssertEqual(hosts,["translate.google.com"])
    }
}
