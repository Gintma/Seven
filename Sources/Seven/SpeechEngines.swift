
/// 可选的朗读服务；本机没有对应语言嗓音时，使用已验证的在线服务，否则不朗读。
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

/// 朗读服务提供的可调项。只列出服务真正支持的参数。
enum SpeechEngineOption: Sendable {
    case englishAccent
    case rate
}

struct SpeechEngineDescriptor: Identifiable, Sendable {
    let id: SpeechEngineID
    let title: String
    let isOnline: Bool
    /// 在线服务的请求主机，用于设置页的隐私说明和诊断日志。
    let host: String?
    /// 单次朗读字符上限；超出时选择其他可用服务，全部不可用则停止。nil 表示不限。
    let maximumCharacters: Int?
    /// 已验证的在线语言，或本机运行时可用的系统语言。
    let supportedLanguages: [String]
    let options: [SpeechEngineOption]
}

enum SpeechEngineCatalog {
    /// 在线覆盖于 2026-11-01 用三家 × 30 种语言的可解码音频探测核对；字数上限沿用已有保守值。
    /// 有道英文约 800 字截断、中文 1200 字返回 400；
    /// 百度仅中/英/日/韩可用；谷歌 360 字时返回 400。有道、谷歌的语速由本地倍速播放实现。
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
