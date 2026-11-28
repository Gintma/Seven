import Foundation

/// Lists only verified models; nil represents the default and omits the parameter entirely.
enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case none, minimal, low, medium, high, xhigh, max
    var title: String {
        switch self {
        case .none: return L10n.text("off")
        case .minimal: return L10n.text("minimal")
        case .low: return L10n.text("low")
        case .medium: return L10n.text("medium")
        case .high: return L10n.text("high")
        case .xhigh: return L10n.text("veryHigh")
        case .max: return L10n.text("maximum")
        }
    }
}

/// Verified 2026-11-05. Centralizes parameter differences based on verified models and selected protocol, without restricting by official or relay domains.
enum ServiceReasoning {
    static func options(provider: ServiceProvider?, model: String, style: ServiceAPIStyle) -> [ReasoningEffort] {
        guard let provider = parameterProvider(provider, style: style) else { return [] }
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .openAI where style == .openAIResponses || style == .openAICompatible:
            switch name {
            case "gpt-6-sol", "gpt-6-luna": return [.none, .low, .medium, .high, .xhigh, .max]
            case "gpt-6-astra", "gpt-6.1-sol": return [.low, .medium, .high, .xhigh, .max]
            default: return []
            }
        case .claude where style == .anthropic:
            switch name {
            case "claude-opus-4-6", "claude-sonnet-4-6": return [.low, .medium, .high, .max]
            case "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5", "claude-opus-5-5",
                 "claude-sonnet-5", "claude-sonnet-5-5", "claude-haiku-5-5",
                 "claude-fable-5", "claude-fable-5-1", "claude-mythos-5", "claude-mythos-5-1":
                return [.low, .medium, .high, .xhigh, .max]
            default: return []
            }
        case .gemini where style == .gemini:
            switch name {
            case "gemini-4-argon", "gemini-3.8-flash", "gemini-3.1-pro-preview": return [.low, .medium, .high]
            case "gemini-3.6-flash", "gemini-3.5-flash-lite", "gemini-3-flash-preview": return [.minimal, .low, .medium, .high]
            case "gemini-3.1-flash-lite-image": return [.minimal, .high]
            default: return []
            }
        case .deepSeek where style == .openAICompatible:
            return ["deepseek-flash", "deepseek-v4-pro"].contains(name) ? [.none, .low, .high, .max] : []
        default: return []
        }
    }

    private static func parameterProvider(_ provider: ServiceProvider?, style: ServiceAPIStyle) -> ServiceProvider? {
        guard provider == .custom else { return provider }
        // A custom service's explicit protocol determines the parameter format, while the model must still match the capability table below exactly.
        switch style {
        case .openAIResponses, .openAICompatible: return .openAI
        case .anthropic: return .claude
        case .gemini: return .gemini
        }
    }

    static func apply(to body: inout [String: Any], configuration: ServiceConfiguration) {
        guard let effort = configuration.reasoningEffort,
              options(provider: configuration.reasoningProvider, model: configuration.requestModel,
                      style: configuration.apiStyle).contains(effort) else { return }
        switch parameterProvider(configuration.reasoningProvider, style: configuration.apiStyle) {
        case .openAI:
            if configuration.apiStyle == .openAIResponses { body["reasoning"] = ["effort": effort.rawValue] }
            else { body["reasoning_effort"] = effort.rawValue }
        case .claude: body["output_config"] = ["effort": effort.rawValue]
        case .gemini: body["generationConfig"] = ["thinkingConfig": ["thinkingLevel": effort.rawValue.uppercased()]]
        case .deepSeek:
            body["thinking"] = ["type": effort == .none ? "disabled" : "enabled"]
            if effort != .none { body["reasoning_effort"] = effort.rawValue }
        default: break
        }
    }
}
