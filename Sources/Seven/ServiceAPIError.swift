import Foundation

/// 只将服务错误映射到固定类别，不向界面或日志传递服务端的任意正文。
enum ServiceAPIError {
    static func mapped(_ error: Any?, status: Int? = nil) -> TranslationError {
        if let status, [401, 403, 429].contains(status) { return .http(status) }
        let fields = error as? [String: Any] ?? [:]
        let code = (fields["code"] as? String ?? fields["type"] as? String ?? "").lowercased()
        let parameter = (fields["param"] as? String ?? "").lowercased()
        let message = (fields["message"] as? String ?? error as? String ?? "").lowercased()
        if ["model_not_found", "invalid_model", "model_not_available"].contains(code) {
            return .modelUnavailable
        }
        if ["invalid_api_key", "authentication_error", "permission_denied"].contains(code) { return .http(401) }
        if ["insufficient_quota", "rate_limit_exceeded", "rate_limit_error"].contains(code) { return .http(429) }
        if code == "unsupported_parameter" || code == "unsupported_value" || code == "invalid_parameter" {
            if ["reasoning", "reasoning.effort", "reasoning_effort", "thinking", "output_config.effort", "generationconfig.thinkingconfig"].contains(parameter) {
                return .configuration(.key("service.reasoningUnsupported"))
            }
            return .configuration(.key("theServiceRejectedTheCurrentParametersCheck"))
        }
        let unsupported = ["unsupported_endpoint", "endpoint_not_found", "unknown_endpoint", "unsupported_api", "not_implemented"].contains(code)
        let routeMessage = ["endpoint not supported", "endpoint is not supported", "unsupported endpoint", "unsupported path", "unknown route", "route not found", "cannot post", "responses not supported", "does not support the responses", "does not support /v1/responses"].contains { message.contains($0) }
        let namedFormatUnsupported = (message.contains("responses") || message.contains("chat/completions")) &&
            ["not supported", "unsupported", "does not support"].contains { message.contains($0) }
        if unsupported || routeMessage || namedFormatUnsupported || status == 405 || status == 501 { return .endpointUnsupported }
        // 无结构化错误的 404（常见为 HTML/空响应）才按路径不存在处理。
        if status == 404, error == nil { return .endpointUnsupported }
        if parameter == "model" { return .modelUnavailable }
        if let status { return .http(status) }
        return .transport(.key("theServiceReturnedAnErrorCheckIts"))
    }

    static func response(_ data: Data, status: Int) -> TranslationError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let topLevelError: Any? = object?["message"] != nil || object?["code"] != nil ? object : nil
        return mapped(object?["error"] ?? topLevelError, status: status)
    }
}
