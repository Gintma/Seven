import Foundation

/// 提供方决定预设与品牌；实例 ID 决定凭据、任务和卡片身份。
enum ServiceProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple, google, youdao, dictionary
    case openAI, claude, gemini, deepSeek, miniMax, zhipu, kimi, qwen, doubao, openRouter, custom
    var id: Self { self }
    static let builtIns: [Self] = [.apple, .google, .youdao, .dictionary]
    static let keyProviders: [Self] = [.openAI, .claude, .gemini, .deepSeek, .miniMax, .zhipu, .kimi, .qwen, .doubao, .openRouter, .custom]
    var isBuiltIn: Bool { Self.builtIns.contains(self) }
    var title: String {
        switch self {
        case .apple: return L10n.text("appleTranslation")
        case .google: return L10n.text("googleTranslate")
        case .youdao: return L10n.text("youdaoTranslate")
        case .dictionary: return L10n.text("englishChineseDictionary")
        case .openAI: return "OpenAI"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .deepSeek: return "DeepSeek"
        case .miniMax: return "MiniMax"
        case .zhipu: return L10n.text("zhipuAI")
        case .kimi: return "Kimi"
        case .qwen: return L10n.text("qwen")
        case .doubao: return L10n.text("doubao")
        case .openRouter: return "OpenRouter"
        case .custom: return L10n.text("custom")
        }
    }
    var builtInID: TranslationProviderID? {
        switch self {
        case .apple: return .appleTranslation
        case .google: return .google
        case .youdao: return .youdao
        case .dictionary: return .ecdict
        default: return nil
        }
    }
    var apiStyle: ServiceAPIStyle {
        switch self {
        case .openAI: return .openAIResponses
        case .claude: return .anthropic
        case .gemini: return .gemini
        default: return .openAICompatible
        }
    }
    // 2026-11-04 核对各家官方文档。
    var baseAddress: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .claude: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .deepSeek: return "https://api.deepseek.com"
        case .miniMax: return "https://api.minimax.io/v1"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .kimi: return "https://api.moonshot.cn/v1"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .doubao: return "https://ark.cn-beijing.volces.com/api/v3"
        case .openRouter: return "https://openrouter.ai/api/v1"
        default: return ""
        }
    }
    // 默认模型同上官方来源，2026-11-04 核对；不覆盖用户迁移过来的原模型。
    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-6-luna"
        case .claude: return "claude-haiku-5-5"
        case .gemini: return "gemini-3.8-flash"
        case .deepSeek: return "deepseek-flash"
        case .miniMax: return "MiniMax-M3.1-Flash"
        case .zhipu: return "glm-5.3"
        case .kimi: return "kimi-k3.1-pro"
        case .qwen: return "qwen-plus"
        // 豆包接入点由用户在火山方舟控制台取得，不伪造可调用 ID。
        default: return ""
        }
    }
    static func inferred(from config: ServiceConfiguration) -> Self {
        let host = URLComponents(string: config.endpoint)?.host?.lowercased() ?? ""
        return keyProviders.first { !$0.baseAddress.isEmpty && URLComponents(string: $0.baseAddress)?.host == host } ?? .custom
    }
}

struct ServiceInstance: Identifiable, Codable, Equatable, Sendable {
    let id: TranslationProviderID
    let provider: ServiceProvider
    var name: String
    var enabled: Bool
    var baseAddress: String
    var apiStyle: ServiceAPIStyle
    var model: String
    var mode: TranslationMode
    var systemPrompt: String
    var userPrompt: String
    var timeoutSeconds: Int
    var reasoningEffort: ReasoningEffort?
    var detectedAPIStyle: ServiceAPIStyle?
    // Optional 保持旧服务配置可解码；新增模型只跟随所属实例保存。
    private var addedModels: [String]?
    private var cachedModels: [String]?
    var fetchedModels: [String] {
        get { cachedModels ?? [] }
        set { cachedModels = newValue }
    }
    var manualModels: [String] {
        get { addedModels ?? [] }
        set { addedModels = newValue }
    }

    func requiresModelCatalogInvalidation(comparedTo previous: ServiceInstance) -> Bool {
        id == previous.id && (previous.baseAddress != baseAddress || previous.apiStyle != apiStyle)
    }

    init(provider: ServiceProvider, id: TranslationProviderID? = nil, name: String? = nil, enabled: Bool = true) {
        self.id = id ?? provider.builtInID ?? TranslationProviderID(rawValue: "instance-" + UUID().uuidString)
        self.provider = provider; self.name = name ?? provider.title; self.enabled = enabled
        baseAddress = provider.baseAddress; apiStyle = provider.apiStyle; model = provider.defaultModel
        mode = .translate; systemPrompt = ""; userPrompt = ""; timeoutSeconds = 60
    }
    var displayName: String { provider.isBuiltIn ? provider.title : name }
    var brandName: String { provider == .custom ? name : provider.title }
    var configuration: ServiceConfiguration {
        let style = provider == .openAI ? (detectedAPIStyle ?? apiStyle) : apiStyle
        var config = ServiceConfiguration(name: name, endpoint: ServiceEndpoint.requestAddress(base: baseAddress, style: style, model: model), model: model, mode: mode, systemPrompt: systemPrompt, userPrompt: userPrompt, timeoutSeconds: timeoutSeconds, apiStyle: style)
        config.reasoningEffort = reasoningEffort
        config.reasoningProvider = provider
        config.instanceID = id.rawValue
        return config
    }
    mutating func apply(_ config: ServiceConfiguration) {
        name = config.name; baseAddress = ServiceEndpoint.normalizedBase(config.endpoint)
        let standardOpenAI = provider == .openAI && [ServiceAPIStyle.openAIResponses, .openAICompatible].contains(config.apiStyle)
        apiStyle = provider == .custom || standardOpenAI ? config.apiStyle : provider.apiStyle
        model = config.model; mode = config.mode; systemPrompt = config.systemPrompt; userPrompt = config.userPrompt
        timeoutSeconds = config.timeoutSeconds
        reasoningEffort = config.reasoningEffort
    }
}

enum ServiceEndpoint {
    static func pastedOpenAIStyle(_ value: String) -> ServiceAPIStyle? {
        guard let path = URLComponents(string: value)?.path else { return nil }
        if path.hasSuffix("/chat/completions") { return .openAICompatible }
        if path.hasSuffix("/responses") { return .openAIResponses }
        return nil
    }

    /// 只在完整请求后缀已出现时归一化输入框；普通路径末尾的 / 保留，避免打断逐字输入。
    static func pastedBase(_ value: String) -> String? {
        let path = URLComponents(string: value)?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let known = ["chat/completions", "responses", "messages", ":generateContent", ":streamGenerateContent"]
        guard known.contains(where: { path.hasSuffix($0) }) else { return nil }
        let base = normalizedBase(value)
        return base == value ? nil : base
    }

    static func normalizedBase(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text), parts.fragment == nil else { return text }
        if parts.queryItems == [URLQueryItem(name: "alt", value: "sse")] { parts.query = nil }
        guard parts.query == nil else { return text }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/chat/completions", "/responses", "/messages"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count); break
        }
        if let range = path.range(of: "/models/", options: .backwards),
           path[range.lowerBound...].contains(":generateContent") || path[range.lowerBound...].contains(":streamGenerateContent") {
            path = String(path[..<range.lowerBound])
        }
        parts.path = path
        return parts.string ?? text
    }
    static func requestAddress(base: String, style: ServiceAPIStyle, model: String) -> String {
        let base = normalizedBase(base)
        guard var parts = URLComponents(string: base) else { return base }
        switch style {
        case .openAICompatible: parts.path += "/chat/completions"
        case .openAIResponses: parts.path += "/responses"
        case .anthropic: parts.path += "/messages"
        case .gemini: parts.path += "/models/" + model.replacingOccurrences(of: "models/", with: "") + ":generateContent"
        }
        return parts.string ?? base
    }
}
