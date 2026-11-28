import AVFoundation
import CryptoKit
import Foundation

/// A candidate URL for an online speech request; `label` is used only in diagnostic logs and excludes query parameters.
struct OnlineSpeechAttempt: Equatable {
    let url: URL
    let label: String
}

/// Builds speech audio URLs per service. Parameters were verified against live endpoints on 2026-10-23; see SpeechEngineCatalog.
enum OnlineSpeechURLBuilder {
    /// Returns candidate URLs in priority order; falls back to the next one if the previous fails.
    static func attempts(
        engine: SpeechEngineID,
        text: String,
        language: String,
        accent: SpeechEnglishAccent,
        rate: SpeechRate,
        now: Date = Date()
    ) -> [OnlineSpeechAttempt] {
        let isEnglish = language == "en"
        switch engine {
        case .system:
            return []
        case .youdao:
            // Prefer Youdao Translate's full-sentence web TTS endpoint; fall back to dictionary-only dictvoice if the signing constant breaks.
            var result: [OnlineSpeechAttempt] = []
            if let code = youdaoPronounceCodes[language],
               let url = youdaoPronounceURL(text: text, le: code, voiceType: accent == .uk ? 1 : 2, now: now) {
                result.append(.init(url: url, label: "pronounce"))
            }
            if let code = youdaoDictionaryCodes[language] {
                var query = [("audio", text), ("le", code)]
                if isEnglish { query.append(("type", accent == .uk ? "1" : "2")) }
                if let url = build("https://dict.youdao.com/dictvoice", query) {
                    result.append(.init(url: url, label: "dictvoice"))
                }
            }
            return result
        case .baidu:
            guard let code = baiduCodes[language] else { return [] }
            let lan = isEnglish && accent == .uk ? "uk" : code
            // Baidu defaults to speed 5 for Chinese and 3 for other languages, with slow and fast offset by 2 steps each.
            let base = language == "zh-Hans" ? 5 : 3
            let speed = base + (rate == .slow ? -2 : rate == .fast ? 2 : 0)
            return build("https://fanyi.baidu.com/gettts", [
                ("text", text), ("lan", lan), ("spd", String(speed)), ("source", "web")
            ]).map { [.init(url: $0, label: "gettts")] } ?? []
        case .google:
            guard var code = googleCodes[language] else { return [] }
            if isEnglish { code = accent == .uk ? "en-GB" : "en-US" }
            return build("https://translate.google.com/translate_tts", [
                ("ie", "UTF-8"), ("q", text), ("tl", code), ("client", "tw-ob")
            ]).map { [.init(url: $0, label: "translate_tts")] } ?? []
        }
    }

    /// Youdao and Google return fixed-rate audio whose speed is adjusted locally by the player (matching Youdao's web UI); Baidu synthesizes speed server-side.
    static func playbackRate(engine: SpeechEngineID, rate: SpeechRate) -> Float {
        guard engine == .youdao || engine == .google else { return 1 }
        switch rate {
        case .slow: return 0.75
        case .normal: return 1
        case .fast: return 1.25
        }
    }

    /// Public parameter constants used by Youdao web TTS; unrelated to user credentials.
    private static let youdaoVoiceKeyID = "voiceFanyiWeb"
    private static let youdaoVoiceProduct = "webfanyi"
    private static let youdaoVoiceSecret = "qCG2vdP92hOXDcKa"

    /// Drops empty values, sorts by key name, appends key=<constant>, and computes the MD5 digest. pointParam lists the signed keys.
    static func youdaoPronounceURL(text: String, le: String, voiceType: Int, now: Date) -> URL? {
        var parameters: [String: String] = [
            "product": youdaoVoiceProduct, "appVersion": "1", "client": "web", "mid": "1", "vendor": "web",
            "screen": "1", "model": "1", "imei": "1", "network": "wifi", "keyid": youdaoVoiceKeyID,
            "mysticTime": String(Int64(now.timeIntervalSince1970 * 1000)), "yduuid": "abcdefg",
            "le": le, "rate": "4", "word": text, "type": String(voiceType)
        ]
        let keys = parameters.keys.filter { !(parameters[$0] ?? "").isEmpty }.sorted()
        let signed = keys.map { "\($0)=\(parameters[$0] ?? "")" }.joined(separator: "&") + "&key=\(youdaoVoiceSecret)"
        parameters["sign"] = Insecure.MD5.hash(data: Data(signed.utf8)).map { String(format: "%02x", $0) }.joined()
        parameters["pointParam"] = (keys + ["key"]).joined(separator: ",")
        return build("https://dict.youdao.com/pronounce/base", parameters.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }

    // Candidate speech codes verified by playable-audio probes, 2026-11-01.
    static let youdaoPronounceCodes = [
        "zh-Hans": "zh",
        "zh-Hant": "zh",
        "en": "en",
        "ja": "ja",
        "ko": "ko",
        "fr": "fr",
        "de": "de",
        "es": "es",
        "pt": "pt",
        "it": "it",
        "ru": "ru",
        "nl": "nl",
        "pl": "pl",
        "sv": "sv",
        "uk": "uk",
        "el": "el",
        "tr": "tr",
        "cs": "cs",
        "vi": "vi",
        "th": "th",
        "id": "id",
        "ms": "ms",
        "hi": "hi",
        "ar": "ar",
        "he": "he"
    ]
    static let youdaoDictionaryCodes = [
        "zh-Hans": "zh",
        "en": "en",
        "ja": "ja",
        "ko": "ko",
        "es": "es"
    ]
    static let baiduCodes = [
        "zh-Hans": "zh",
        "zh-Hant": "zh",
        "en": "en",
        "ja": "jp",
        "ko": "kor"
    ]
    static let googleCodes = [
        "zh-Hans": "zh-CN",
        "zh-Hant": "zh-TW",
        "en": "en",
        "ja": "ja",
        "ko": "ko",
        "fr": "fr",
        "de": "de",
        "es": "es",
        "pt": "pt",
        "it": "it",
        "ru": "ru",
        "nl": "nl",
        "pl": "pl",
        "sv": "sv",
        "uk": "uk",
        "el": "el",
        "tr": "tr",
        "cs": "cs",
        "vi": "vi",
        "th": "th",
        "id": "id",
        "ms": "ms",
        "hi": "hi",
        "ar": "ar",
        "he": "iw",
        "fil": "tl",
        "bn": "bn",
        "ur": "ur",
        "sw": "sw"
    ]
    /// Strictly percent-encodes query values so characters like `+` and `&` are not misinterpreted by the server.
    private static let queryValueAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    private static func build(_ base: String, _ query: [(String, String)]) -> URL? {
        let encoded = query.compactMap { name, value -> String? in
            guard let value = value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) else { return nil }
            return "\(name)=\(value)"
        }
        guard encoded.count == query.count else { return nil }
        return URL(string: "\(base)?\(encoded.joined(separator: "&"))")
    }
}

/// Decides whether speech should use an online service; returns nil to fall back to system speech.
enum SpeechRoutingPolicy {
    static func onlineEngine(
        selected: SpeechEngineID,
        text: String,
        language: String?
    ) -> SpeechEngineID? {
        let descriptor = SpeechEngineCatalog.descriptor(for: selected)
        guard descriptor.isOnline,
              let language,
              descriptor.supportedLanguages.contains(language) else { return nil }
        if let limit = descriptor.maximumCharacters, text.count > limit { return nil }
        return selected
    }
}

enum SpeechAudioError: Error, Equatable {
    case http(Int)
    case notAudio
    case transport

    /// Fixed category written to diagnostic logs.
    var diagnosticCategory: String {
        switch self {
        case .http: return "http"
        case .notAudio: return "not_audio"
        case .transport: return "transport"
        }
    }
}

protocol SpeechAudioFetching: Sendable {
    func audio(from url: URL) async throws -> Data
}

final class URLSessionSpeechAudioFetcher: SpeechAudioFetching, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 12
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
    }

    func audio(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeechAudioError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw SpeechAudioError.transport }
        guard (200..<300).contains(http.statusCode) else { throw SpeechAudioError.http(http.statusCode) }
        guard http.mimeType?.hasPrefix("audio/") == true, !data.isEmpty else { throw SpeechAudioError.notAudio }
        guard let decoded = try? AVAudioPlayer(data: data), decoded.duration > 0 else { throw SpeechAudioError.notAudio }
        return data
    }
}
