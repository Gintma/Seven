import Foundation

struct AIModelCatalog: Sendable {
    let models: [String]
}

final class AIModelCatalogService: @unchecked Sendable {
    static let shared = AIModelCatalogService()

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 45
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(
                configuration: configuration,
                delegate: NoRedirectDelegate(),
                delegateQueue: nil
            )
        }
    }

    deinit { session.invalidateAndCancel() }

    func fetchModels(configuration: ServiceConfiguration, apiKey: String) async throws -> AIModelCatalog {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw TranslationError.configuration("需要 API Key 才能获取模型列表。")
        }
        var request = URLRequest(url: try Self.modelsURL(for: configuration))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if configuration.apiStyle == .anthropic {
            request.setValue(key, forHTTPHeaderField: "X-Api-Key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if configuration.apiStyle == .gemini {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            let fetched = try Self.parse(data, response: response)
            return fetched
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut {
                throw TranslationError.transport("获取模型列表超时，请稍后重试。")
            }
            throw TranslationError.transport("无法获取模型列表，请检查网络和接口地址。")
        }
    }

    static func modelsURL(for configuration: ServiceConfiguration) throws -> URL {
        var catalogConfiguration = configuration
        catalogConfiguration.mode = .translate
        catalogConfiguration.timeoutSeconds = 60
        if catalogConfiguration.model.isEmpty { catalogConfiguration.model = "catalog" }
        let endpoint = try catalogConfiguration.validatedURL()
        guard var components = URLComponents(string: ServiceEndpoint.normalizedBase(endpoint.absoluteString)) else { throw TranslationError.malformed }
        components.path += "/models"
        guard let url = components.url else { throw TranslationError.malformed }
        return url
    }

    static func parse(_ data: Data, response: URLResponse) throws -> AIModelCatalog {
        guard let response = response as? HTTPURLResponse else { throw TranslationError.malformed }
        guard (200..<300).contains(response.statusCode) else { throw TranslationError.http(response.statusCode) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = (object["data"] ?? object["models"]) as? [[String: Any]] else {
            throw TranslationError.malformed
        }
        let models = Array(Set(entries.filter { entry in
            guard let methods = entry["supportedGenerationMethods"] as? [String] else { return true }
            return methods.contains("generateContent")
        }.compactMap { entry in
            ((entry["id"] ?? entry["name"]) as? String)?.replacingOccurrences(of: "models/", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        guard !models.isEmpty else { throw TranslationError.empty }
        return AIModelCatalog(models: models)
    }
}
