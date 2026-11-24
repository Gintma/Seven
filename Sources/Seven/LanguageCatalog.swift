import Foundation
import NaturalLanguage

/// 一种语言在Seven里的全部信息：标识、显示名，以及各服务使用的代码。
/// 新增语言只需在 `LanguageCatalog.all` 加一行；某服务的代码为 nil 表示该服务不支持。
struct Language: Hashable, Identifiable, Sendable {
    /// 稳定标识（BCP 47 风格），用于保存设置与内部传递，不随界面文案变化。
    let code: String
    /// 界面显示名。
    let nameKey: String
    var name: String { L10n.text(nameKey) }
    /// 写入大模型提示词的名称，用英文以减少歧义。
    let promptName: String
    let googleCode: String?
    let youdaoCode: String?
    /// Apple 翻译与系统朗读使用的区域标识。
    let appleLocale: String?
    let speechLocale: String?
    let detection: NLLanguage?

    var id: String { code }
}

enum LanguageCatalog {
    /// 源语言为自动检测、目标语言为自动选择时使用的标识。
    static let automatic = "auto"
    static let defaultPrimary = "zh-Hans"
    static let defaultSecondary = "en"
    /// 语言栏菜单默认直接列出的常用语言（即扩充前的 9 种），其余在“更多语言”里。
    static let defaultCommon = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "ru"]

    /// 30 种语言。Apple 翻译与系统朗读的支持情况于 2026-10-30 在 macOS 26 上用
    /// `LanguageAvailability().supportedLanguages` 与 `AVSpeechSynthesisVoice.speechVoices()` 核对；
    /// Google、有道的代码由 `SEVEN_LIVE_TRANSLATION_TESTS` 联网测试逐一核对（2026-10-30）。nil 表示不支持。
    /// 有道网页接口另有语言对限制，见 `ServiceLanguageSupport`。
    static let all: [Language] = [
        // 中日韩与英语
        Language(code: "zh-Hans", nameKey: "simplifiedChinese", promptName: "Simplified Chinese",
                 googleCode: "zh-CN", youdaoCode: "zh-CHS", appleLocale: "zh-Hans", speechLocale: "zh-CN",
                 detection: .simplifiedChinese),
        Language(code: "zh-Hant", nameKey: "traditionalChinese", promptName: "Traditional Chinese",
                 googleCode: "zh-TW", youdaoCode: "zh-CHT", appleLocale: "zh-Hant", speechLocale: "zh-TW",
                 detection: .traditionalChinese),
        Language(code: "en", nameKey: "english", promptName: "English",
                 googleCode: "en", youdaoCode: "en", appleLocale: "en", speechLocale: "en-US",
                 detection: .english),
        Language(code: "ja", nameKey: "japanese", promptName: "Japanese",
                 googleCode: "ja", youdaoCode: "ja", appleLocale: "ja", speechLocale: "ja-JP",
                 detection: .japanese),
        Language(code: "ko", nameKey: "korean", promptName: "Korean",
                 googleCode: "ko", youdaoCode: "ko", appleLocale: "ko", speechLocale: "ko-KR",
                 detection: .korean),
        // 欧洲
        Language(code: "fr", nameKey: "french", promptName: "French",
                 googleCode: "fr", youdaoCode: "fr", appleLocale: "fr", speechLocale: "fr-FR",
                 detection: .french),
        Language(code: "de", nameKey: "german", promptName: "German",
                 googleCode: "de", youdaoCode: "de", appleLocale: "de", speechLocale: "de-DE",
                 detection: .german),
        Language(code: "es", nameKey: "spanish", promptName: "Spanish",
                 googleCode: "es", youdaoCode: "es", appleLocale: "es", speechLocale: "es-ES",
                 detection: .spanish),
        Language(code: "pt", nameKey: "portuguese", promptName: "Portuguese",
                 googleCode: "pt", youdaoCode: "pt", appleLocale: "pt-BR", speechLocale: "pt-BR",
                 detection: .portuguese),
        Language(code: "it", nameKey: "italian", promptName: "Italian",
                 googleCode: "it", youdaoCode: "it", appleLocale: "it", speechLocale: "it-IT",
                 detection: .italian),
        Language(code: "ru", nameKey: "russian", promptName: "Russian",
                 googleCode: "ru", youdaoCode: "ru", appleLocale: "ru", speechLocale: "ru-RU",
                 detection: .russian),
        Language(code: "nl", nameKey: "dutch", promptName: "Dutch",
                 googleCode: "nl", youdaoCode: "nl", appleLocale: "nl", speechLocale: "nl-NL",
                 detection: .dutch),
        Language(code: "pl", nameKey: "polish", promptName: "Polish",
                 googleCode: "pl", youdaoCode: nil, appleLocale: "pl", speechLocale: "pl-PL",
                 detection: .polish),
        Language(code: "sv", nameKey: "swedish", promptName: "Swedish",
                 googleCode: "sv", youdaoCode: nil, appleLocale: nil, speechLocale: "sv-SE",
                 detection: .swedish),
        Language(code: "uk", nameKey: "ukrainian", promptName: "Ukrainian",
                 googleCode: "uk", youdaoCode: nil, appleLocale: "uk", speechLocale: "uk-UA",
                 detection: .ukrainian),
        Language(code: "el", nameKey: "greek", promptName: "Greek",
                 googleCode: "el", youdaoCode: nil, appleLocale: nil, speechLocale: "el-GR",
                 detection: .greek),
        Language(code: "tr", nameKey: "turkish", promptName: "Turkish",
                 googleCode: "tr", youdaoCode: nil, appleLocale: "tr", speechLocale: "tr-TR",
                 detection: .turkish),
        Language(code: "cs", nameKey: "czech", promptName: "Czech",
                 googleCode: "cs", youdaoCode: nil, appleLocale: nil, speechLocale: "cs-CZ",
                 detection: .czech),
        // 亚洲及其他
        Language(code: "vi", nameKey: "vietnamese", promptName: "Vietnamese",
                 googleCode: "vi", youdaoCode: "vi", appleLocale: "vi", speechLocale: "vi-VN",
                 detection: .vietnamese),
        Language(code: "th", nameKey: "thai", promptName: "Thai",
                 googleCode: "th", youdaoCode: "th", appleLocale: "th", speechLocale: "th-TH",
                 detection: .thai),
        Language(code: "id", nameKey: "indonesian", promptName: "Indonesian",
                 googleCode: "id", youdaoCode: "id", appleLocale: "id", speechLocale: "id-ID",
                 detection: .indonesian),
        Language(code: "ms", nameKey: "malay", promptName: "Malay",
                 googleCode: "ms", youdaoCode: nil, appleLocale: nil, speechLocale: "ms-MY",
                 detection: .malay),
        Language(code: "hi", nameKey: "hindi", promptName: "Hindi",
                 googleCode: "hi", youdaoCode: "hi", appleLocale: "hi", speechLocale: "hi-IN",
                 detection: .hindi),
        Language(code: "ar", nameKey: "arabic", promptName: "Arabic",
                 googleCode: "ar", youdaoCode: "ar", appleLocale: "ar", speechLocale: "ar-001",
                 detection: .arabic),
        Language(code: "fa", nameKey: "persian", promptName: "Persian",
                 googleCode: "fa", youdaoCode: nil, appleLocale: nil, speechLocale: nil,
                 detection: .persian),
        Language(code: "he", nameKey: "hebrew", promptName: "Hebrew",
                 googleCode: "iw", youdaoCode: nil, appleLocale: nil, speechLocale: "he-IL",
                 detection: .hebrew),
        Language(code: "fil", nameKey: "filipino", promptName: "Filipino",
                 googleCode: "tl", youdaoCode: nil, appleLocale: nil, speechLocale: nil,
                 detection: nil),
        Language(code: "bn", nameKey: "bengali", promptName: "Bengali",
                 googleCode: "bn", youdaoCode: nil, appleLocale: nil, speechLocale: "bn-IN",
                 detection: .bengali),
        Language(code: "ur", nameKey: "urdu", promptName: "Urdu",
                 googleCode: "ur", youdaoCode: nil, appleLocale: nil, speechLocale: nil,
                 detection: .urdu),
        Language(code: "sw", nameKey: "swahili", promptName: "Swahili",
                 googleCode: "sw", youdaoCode: nil, appleLocale: nil, speechLocale: nil,
                 detection: nil)
    ]

    static let codes: [String] = all.map(\.code)

    private static let byCode: [String: Language] = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })

    static func language(_ code: String) -> Language? { byCode[code] }

    /// 界面显示名；未知代码原样返回。
    static func name(_ code: String) -> String {
        if code == automatic { return L10n.text("auto") }
        return byCode[code]?.name ?? code
    }

    private static let detectionPrefix = 1_000

    /// 历史记录里的语言：新记录存代码，旧记录存显示名，统一换成当前显示名。
    static func displayName(stored: String) -> String { name(migrate(stored)) }

    /// 系统识别对短中文常分不清简繁（如“你好”会被认成繁体）。
    /// 转成简体后有变化，说明含繁体专用字，才算繁体；否则按简体。
    static func chineseVariant(of text: String) -> String {
        let simplified = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        return simplified == text ? "zh-Hans" : "zh-Hant"
    }

    static func isChinese(_ code: String) -> Bool { code == "zh-Hans" || code == "zh-Hant" }

    // 语言识别对首选和次选语言候选分别加权。
    static let primaryDetectionBonus = 0.4
    static let secondaryDetectionBonus = 0.3
    static let detectionCandidateCount = 5

    /// 只对系统实际返回的候选加分；参数显式传入，不读取用户设置。
    static func preferredDetectionCandidate(_ candidates: [String: Double], primary: String, secondary: String) -> String? {
        func matches(_ candidate: String, _ preference: String) -> Bool {
            // 简繁候选各自获得同一中文偏好加分，不相加概率；最终字形仍由 chineseVariant 决定。
            candidate == preference || (isChinese(candidate) && isChinese(preference))
        }
        return candidates.keys.sorted { lhs, rhs in
            func score(_ code: String) -> Double {
                (candidates[code] ?? 0) + (matches(code, primary) ? primaryDetectionBonus : 0) + (matches(code, secondary) ? secondaryDetectionBonus : 0)
            }
            if score(lhs) != score(rhs) { return score(lhs) > score(rhs) }
            if candidates[lhs] != candidates[rhs] { return (candidates[lhs] ?? 0) > (candidates[rhs] ?? 0) }
            return lhs < rhs
        }.first
    }

    static func detectedCode(for text: String, primary: String = defaultPrimary, secondary: String = defaultSecondary) -> String? {
        // 只看开头一段，保留既有的检测长度上限。
        let trimmed = text.prefix(detectionPrefix).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let candidates = Dictionary(uniqueKeysWithValues: recognizer.languageHypotheses(withMaximum: detectionCandidateCount).map { ($0.key.rawValue, $0.value) })
        guard let winner = preferredDetectionCandidate(candidates, primary: primary, secondary: secondary) else { return nil }
        if isChinese(winner) { return chineseVariant(of: trimmed) }
        return all.first { $0.detection?.rawValue == winner }?.code
    }

    /// 旧版本以显示名保存语言（如 "English"、"繁體中文"），读取设置时换成代码。
    static func migrate(_ stored: String) -> String {
        if byCode[stored] != nil || stored == automatic { return stored }
        return legacyNames[stored] ?? stored
    }

    private static let legacyNames: [String: String] = [
        "简体中文": "zh-Hans", "繁體中文": "zh-Hant", "English": "en", "日本語": "ja", "한국어": "ko",
        "Français": "fr", "Deutsch": "de", "Español": "es", "Русский": "ru",
        "自动检测": automatic, "自动选择": automatic
    ]
}

/// 各翻译服务能否处理某次请求的源语言与目标语言。大模型服务支持全部语言。
enum ServiceLanguageSupport {
    /// 有道网页接口只支持与中文互译的语言（2026-10-30 联网核对：英语→葡萄牙语返回错误码 40，中文→葡萄牙语正常）。
    static let youdaoChineseOnly: Set<String> = ["pt"]

    /// 返回该服务不支持的那一方语言代码；nil 表示支持。
    /// `source` 为自动时应传入检测结果；检测不出时传 `LanguageCatalog.automatic`，视为支持。
    static func unsupportedLanguage(_ provider: TranslationProviderID, source: String, target: String) -> String? {
        let code: (Language) -> String?
        switch provider {
        case .google: code = { $0.googleCode }
        case .youdao: code = { $0.youdaoCode }
        case .appleTranslation: code = { $0.appleLocale }
        default: return nil
        }
        for language in [target, source] where language != LanguageCatalog.automatic {
            guard let entry = LanguageCatalog.language(language) else { continue }
            if code(entry) == nil { return language }
        }
        if provider == .youdao {
            for (language, other) in [(target, source), (source, target)]
            where youdaoChineseOnly.contains(language) && other != LanguageCatalog.automatic
                && !LanguageCatalog.isChinese(other) {
                return language
            }
        }
        return nil
    }
}
