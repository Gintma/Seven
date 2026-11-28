import Foundation

/// Runs offline system detection first; adopts trusted languages directly, otherwise refines only via the user-selected service,
/// falling back to the system result on failure without switching to another service.
/// System detection lacks support for languages like Swahili and Filipino and misclassifies them as Indonesian; online detection corrects this.
enum LanguageDetectionMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case youdao
    case baidu
    case google

    static let storageKey = "languageDetection.v1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.text("onDeviceDetectionOnly")
        case .youdao: return L10n.text("enhanceWithYoudao")
        case .google: return L10n.text("enhanceWithGoogle")
        case .baidu: return L10n.text("enhanceWithBaidu")
        }
    }

    /// Host to which online detection sends source text; nil for system detection.
    var host: String? {
        switch self {
        case .system: return nil
        case .youdao: return YoudaoTranslationService.translationEndpoint.host(percentEncoded: false)
        case .google: return GoogleLanguageDetector.endpoint.host(percentEncoded: false)
        case .baidu: return BaiduLanguageDetector.endpoint.host(percentEncoded: false)
        }
    }

    /// Queries only the selected online detection service and falls back to the local result on failure.
    var onlineOrder: [LanguageDetectionMode] {
        switch self {
        case .system: return []
        case .youdao: return [.youdao]
        case .google: return [.google]
        case .baidu: return [.baidu]
        }
    }
}

/// Detects source language online and returns a `LanguageCatalog` code, or nil if the detected language is not in the catalog.
protocol OnlineLanguageDetecting: Sendable {
    func detect(_ text: String) async throws -> String?
}

enum LanguageDetectionPolicy {
    /// Maximum characters sent for online detection: language identification does not need the full text.
    static let maximumCharacters = 500

    /// Adopts Chinese, English, Japanese, Korean, and preferred languages directly when local detection has strong evidence.
    private static let trustedLocalLanguages: Set<String> = ["en", "zh-Hans", "zh-Hant", "ja", "ko"]

    static func needsOnlineCheck(local: LocalLanguageDetection, primary: String, secondary: String) -> Bool {
        switch local.evidence {
        case .noLanguageSignal:
            return false
        case .confident:
            guard let code = local.code else { return true }
            return !trustedLocalLanguages.contains(code) && code != primary && code != secondary
        case .preference, .constrained, .mixedAmbiguity, .weakModel:
            return true
        }
    }
}

/// Reuses Google Translate's auto-detected language result (`src` in the response).
struct GoogleLanguageDetector: OnlineLanguageDetecting {
    static let endpoint = GoogleTranslationService.endpoint

    func detect(_ text: String) async throws -> String? {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = try FormEncoding.data([
            ("q", String(text.prefix(LanguageDetectionPolicy.maximumCharacters))),
            ("sl", "auto"), ("tl", "en"), ("dt", "t"), ("dj", "1"), ("ie", "UTF-8"), ("client", "gtx")
        ])
        let (data, response) = try await Self.session.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            throw TranslationError.malformed
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = object["src"] as? String else { throw TranslationError.malformed }
        return code(fromGoogle: source)
    }

    /// Google's language codes differ slightly from the catalog: Chinese includes region subtags, Hebrew uses iw, and Filipino uses tl.
    static func code(fromGoogle value: String) -> String? {
        let key = value.lowercased()
        let aliases = ["zh": "zh-Hans", "zh-cn": "zh-Hans", "zh-tw": "zh-Hant", "iw": "he", "tl": "fil"]
        if let alias = aliases[key] { return alias }
        return LanguageCatalog.all.first { $0.googleCode?.lowercased() == key || $0.code.lowercased() == key }?.code
    }

    private static let session = onlineTranslationSession()
}

/// Baidu Translate web language detection endpoint; verified working on 2026-11-01.
struct BaiduLanguageDetector: OnlineLanguageDetecting {
    static let endpoint = URL(string: "https://fanyi.baidu.com/langdetect")!

    func detect(_ text: String) async throws -> String? {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = try FormEncoding.data([
            ("query", String(text.prefix(LanguageDetectionPolicy.maximumCharacters)))
        ])
        let (data, response) = try await Self.session.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            throw TranslationError.malformed
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["error"] as? Int) == 0,
              let language = object["lan"] as? String else { throw TranslationError.malformed }
        return codes[language]
    }

    /// Baidu language codes -> catalog codes (verified online by testLiveLanguageDetectionCoversCatalog).
    static let codes: [String: String] = [
        "zh": "zh-Hans", "cht": "zh-Hant", "en": "en", "jp": "ja", "kor": "ko", "fra": "fr", "de": "de",
        "spa": "es", "pt": "pt", "it": "it", "ru": "ru", "nl": "nl", "pl": "pl", "swe": "sv", "ukr": "uk",
        "el": "el", "tr": "tr", "cs": "cs", "vie": "vi", "th": "th", "id": "id", "may": "ms", "hi": "hi",
        "ara": "ar", "per": "fa", "heb": "he", "fil": "fil", "ben": "bn", "urd": "ur", "swa": "sw"
    ]

    private static let session = onlineTranslationSession()
}
