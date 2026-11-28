
/// Available speech services; when no local voice exists for a language, falls back to a verified online service, otherwise does not speak.
enum SpeechEngineID: String, CaseIterable, Identifiable, Sendable {
    case system
    case youdao
    case baidu
    case google

    var id: String { rawValue }
}

enum SpeechEnglishAccent: String, CaseIterable, Identifiable, Sendable {
    case us
    case uk

    var id: String { rawValue }
    var title: String { self == .us ? L10n.text("us") : L10n.text("uk") }
}

enum SpeechRate: String, CaseIterable, Identifiable, Sendable {
    case slow
    case normal
    case fast

    var id: String { rawValue }
    var title: String {
        switch self {
        case .slow: return L10n.text("slow")
        case .normal: return L10n.text("normal")
        case .fast: return L10n.text("fast")
        }
    }
}

/// Configurable options exposed by a speech service. Lists only parameters the service genuinely supports.
enum SpeechEngineOption: Sendable {
    case englishAccent
    case rate
}

struct SpeechEngineDescriptor: Identifiable, Sendable {
    let id: SpeechEngineID
    let title: String
    let isOnline: Bool
    /// Request host of an online service, used for settings privacy notes and diagnostic logs.
    let host: String?
    /// Per-request character limit; falls back to another eligible service if exceeded, or stops if none are available. nil means unlimited.
    let maximumCharacters: Int?
    /// Verified online languages, or system languages available at runtime on this Mac.
    let supportedLanguages: [String]
    let options: [SpeechEngineOption]
}

enum SpeechEngineCatalog {
    /// Online coverage verified on 2026-11-01 by probing decodable audio across 3 providers x 30 languages; character limits retain existing conservative values.
    /// Youdao truncates English around 800 characters and returns 400 for 1200 Chinese characters;
    /// Baidu supports only zh/en/ja/ko; Google returns 400 at 360 characters. Speech rate for Youdao and Google is handled via local playback speed.
    static var all: [SpeechEngineDescriptor] { [
        SpeechEngineDescriptor(
            id: .system,
            title: L10n.text("systemSpeech"),
            isOnline: false,
            host: nil,
            maximumCharacters: nil,
            supportedLanguages: LanguageCatalog.codes.filter { SystemSpeechAvailability.voiceLanguage(for: $0, installed: SystemSpeechAvailability.installedLanguages) != nil },
            options: [.rate]
        ),
        SpeechEngineDescriptor(
            id: .youdao,
            title: L10n.text("youdaoSpeech"),
            isOnline: true,
            host: "dict.youdao.com",
            maximumCharacters: 500,
            supportedLanguages: LanguageCatalog.codes.filter { OnlineSpeechURLBuilder.youdaoPronounceCodes[$0] != nil },
            options: [.englishAccent, .rate]
        ),
        SpeechEngineDescriptor(
            id: .baidu,
            title: L10n.text("baiduSpeech"),
            isOnline: true,
            host: "fanyi.baidu.com",
            maximumCharacters: 500,
            supportedLanguages: LanguageCatalog.codes.filter { OnlineSpeechURLBuilder.baiduCodes[$0] != nil },
            options: [.englishAccent, .rate]
        ),
        SpeechEngineDescriptor(
            id: .google,
            title: L10n.text("googleSpeech"),
            isOnline: true,
            host: "translate.google.com",
            maximumCharacters: 200,
            supportedLanguages: LanguageCatalog.codes.filter { OnlineSpeechURLBuilder.googleCodes[$0] != nil },
            options: [.englishAccent, .rate]
        )
    ] }

    static func descriptor(for id: SpeechEngineID) -> SpeechEngineDescriptor {
        all.first { $0.id == id } ?? all[0]
    }
}
