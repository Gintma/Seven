import Foundation

/// 验证时探测标准接口；正式翻译不执行重试探测。
final class CompatibleConfigurationTester: ServiceConfigurationTesting {
    private let service: TranslationServing
    init(service: TranslationServing = CompatibleTranslationService()) { self.service = service }

    func test(configuration: ServiceConfiguration, apiKey: String, firstLanguage: String = "zh-Hans") async throws -> ServiceConfigurationTestResult {
        _ = try configuration.validatedURL()
        let start = Date()
        let automatic = configuration.reasoningProvider == .openAI && [ServiceAPIStyle.openAIResponses, .openAICompatible].contains(configuration.apiStyle)
        let styles: [ServiceAPIStyle] = automatic
            ? [configuration.apiStyle, configuration.apiStyle == .openAIResponses ? .openAICompatible : .openAIResponses]
            : [configuration.apiStyle]
        for (index, style) in styles.enumerated() {
            try Task.checkCancellation()
            var candidate = configuration
            candidate.apiStyle = style
            candidate.endpoint = ServiceEndpoint.requestAddress(base: configuration.endpoint, style: style, model: configuration.model)
            do {
                _ = try await service.translateStream(TranslationRequest(text: "Connection test", source: "en", target: "en",
                                                                  configuration: candidate, apiKey: apiKey, firstLanguage: firstLanguage)) { _ in }
                try Task.checkCancellation()
                return ServiceConfigurationTestResult(elapsed: Date().timeIntervalSince(start), apiStyle: automatic ? style : nil)
            } catch {
                try Task.checkCancellation()
                guard index < styles.count - 1, error as? TranslationError == .endpointUnsupported else { throw error }
            }
        }
        throw TranslationError.endpointUnsupported
    }
}
