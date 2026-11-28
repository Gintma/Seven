import Foundation
import NaturalLanguage

/// Complete metadata for a language in Seven: identifier, display name, and per-service language codes.
/// Add a new language by inserting one row in `LanguageCatalog.all`; a nil service code marks that service as unsupported.
struct Language: Hashable, Identifiable, Sendable {
    /// Stable identifier (BCP 47 style) used for settings persistence and internal routing, independent of UI copy.
    let code: String
    /// UI display name.
    let nameKey: String
    var name: String { L10n.text(nameKey) }
    /// Language name injected into LLM prompts, kept in English to avoid ambiguity.
    let promptName: String
    let googleCode: String?
    let youdaoCode: String?
    /// Locale identifier used by Apple Translation and system speech synthesis.
    let appleLocale: String?
    let speechLocale: String?
    let detection: NLLanguage?

    var id: String { code }
}

enum LanguageCatalog {
    /// Identifier used when source language is auto-detected or target language is auto-selected.
    static let automatic = "auto"
    static let defaultPrimary = "zh-Hans"
    static let defaultSecondary = "en"
    /// Common languages listed directly in the language bar menu (the original 9 before expansion); the rest live under "More Languages".
    static let defaultCommon = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "ru"]

    /// 30 languages. Apple Translation and system speech support verified on macOS 26 (2026-10-30) via
    /// `LanguageAvailability().supportedLanguages` and `AVSpeechSynthesisVoice.speechVoices()`;
    /// Google and Youdao codes verified via `SEVEN_LIVE_TRANSLATION_TESTS` live tests (2026-10-30). nil means unsupported.
    /// Youdao web API has additional language-pair restrictions; see `ServiceLanguageSupport`.
    static let all: [Language] = [
        // CJK and English
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
        // Europe
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
        // Asia and others
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

    /// UI display name; returns unknown codes verbatim.
    static func name(_ code: String) -> String {
        if code == automatic { return L10n.text("auto") }
        return byCode[code]?.name ?? code
    }

    /// Languages stored in history: new entries store codes and legacy entries store display names; normalize all to current display names.
    static func displayName(stored: String) -> String { name(migrate(stored)) }

    static func isChinese(_ code: String) -> Bool { code == "zh-Hans" || code == "zh-Hant" }

    static func localDetection(
        for text: String, primary: String = defaultPrimary, secondary: String = defaultSecondary
    ) -> LocalLanguageDetection {
        LocalLanguageDetector.detect(text, primary: primary, secondary: secondary)
    }

    static func detectedCode(for text: String, primary: String = defaultPrimary, secondary: String = defaultSecondary) -> String? {
        localDetection(for: text, primary: primary, secondary: secondary).code
    }

    /// Legacy versions stored languages by display name (e.g., "English" or localized Chinese names); convert to codes when loading settings.
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

/// Checks whether each translation service supports a request's source and target languages. LLM services support all languages.
enum ServiceLanguageSupport {
    /// Youdao web API only supports language pairs involving Chinese (live-verified 2026-10-30: English -> Portuguese returned error 40, Chinese -> Portuguese succeeded).
    static let youdaoChineseOnly: Set<String> = ["pt"]

    /// Returns the unsupported language code for the service, or nil if supported.
    /// Pass the detected language when `source` is automatic; if detection fails, pass `LanguageCatalog.automatic`, which is treated as supported.
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
