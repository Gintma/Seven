import Foundation

/// 先用系统离线识别；可信语言直接采用，否则仅向用户所选服务优化识别，
/// 所选服务失败时采用系统结果，不切换到其他服务。
/// 系统识别不支持斯瓦希里语、菲律宾语等，会把它们误判为印尼语，联网识别可以纠正。
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

    /// 联网识别会把原文发送到的主机；系统识别为 nil。
    var host: String? {
        switch self {
        case .system: return nil
        case .youdao: return YoudaoTranslationService.translationEndpoint.host(percentEncoded: false)
        case .google: return GoogleLanguageDetector.endpoint.host(percentEncoded: false)
        case .baidu: return BaiduLanguageDetector.endpoint.host(percentEncoded: false)
        }
    }

    /// 仅请求所选联网识别服务，失败后采用本机结果。
    var onlineOrder: [LanguageDetectionMode] {
        switch self {
        case .system: return []
        case .youdao: return [.youdao]
        case .google: return [.google]
        case .baidu: return [.baidu]
        }
    }
}

/// 联网识别原文语言，返回 `LanguageCatalog` 中的代码；识别出的语言不在目录里时返回 nil。
protocol OnlineLanguageDetecting: Sendable {
    func detect(_ text: String) async throws -> String?
}

enum LanguageDetectionPolicy {
    /// 联网识别最多发送的字符数：识别语言用不着全文。
    static let maximumCharacters = 500

    /// 中、英、日、韩以及首选语言在本机有明确证据时直接采用。
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

/// 借用 Google 翻译接口的自动识别结果（响应中的 `src`）。
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

    /// Google 的代码与目录不完全一致：中文带地区、希伯来语用 iw、菲律宾语用 tl。
    static func code(fromGoogle value: String) -> String? {
        let key = value.lowercased()
        let aliases = ["zh": "zh-Hans", "zh-cn": "zh-Hans", "zh-tw": "zh-Hant", "iw": "he", "tl": "fil"]
        if let alias = aliases[key] { return alias }
        return LanguageCatalog.all.first { $0.googleCode?.lowercased() == key || $0.code.lowercased() == key }?.code
    }

    private static let session = onlineTranslationSession()
}

/// 百度翻译网页的语言识别接口，2026-11-01 核对可用。
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

    /// 百度语言代码 → 目录代码（由 testLiveLanguageDetectionCoversCatalog 联网核对）。
    static let codes: [String: String] = [
        "zh": "zh-Hans", "cht": "zh-Hant", "en": "en", "jp": "ja", "kor": "ko", "fra": "fr", "de": "de",
        "spa": "es", "pt": "pt", "it": "it", "ru": "ru", "nl": "nl", "pl": "pl", "swe": "sv", "ukr": "uk",
        "el": "el", "tr": "tr", "cs": "cs", "vie": "vi", "th": "th", "id": "id", "may": "ms", "hi": "hi",
        "ara": "ar", "per": "fa", "heb": "he", "fil": "fil", "ben": "bn", "urd": "ur", "swa": "sw"
    ]

    private static let session = onlineTranslationSession()
}
