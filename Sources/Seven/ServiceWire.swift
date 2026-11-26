import Foundation

/// 四种格式的正文和流事件适配。只解析输出文字，忽略推理/工具调用内容。
/// 协议核对：2026-11-04。
enum ServiceWire {
    static func request(_ input: TranslationRequest) throws -> URLRequest {
        let style = input.configuration.apiStyle
        if style == .openAICompatible { return try CompatibleTranslationService.makeChatURLRequest(input) }
        let endpoint = try input.configuration.validatedURL()
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        if style == .gemini {
            parts?.path = endpoint.servicePath.replacingOccurrences(of: ":generateContent", with: ":streamGenerateContent")
            parts?.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        }
        guard let url = parts?.url else { throw TranslationError.malformed }
        let key = input.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.contains("\n"), !key.contains("\r") else { throw TranslationError.configuration(.key("theAPIKeyCannotContainLineBreaks")) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = TimeInterval(input.configuration.timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let messages = CompatibleTranslationService.makeMessages(input)
        let system = messages.first { $0["role"] == "system" }?["content"]
        let user = messages.first { $0["role"] == "user" }?["content"] ?? input.text
        var body: [String: Any]
        switch style {
        case .anthropic:
            guard !key.isEmpty else { throw TranslationError.configuration(.key("enterAnAPIKey")) }
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": input.configuration.requestModel,
                    "messages": [["role": "user", "content": user]], "max_tokens": 8192, "stream": true]
            if let system { body["system"] = system }
        case .openAIResponses:
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            body = ["model": input.configuration.requestModel, "input": user, "stream": true, "store": false]
            if let system { body["instructions"] = system }
        case .gemini:
            guard !key.isEmpty else { throw TranslationError.configuration(.key("enterAnAPIKey")) }
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            body = ["contents": [["role": "user", "parts": [["text": user]]]]]
            if let system { body["systemInstruction"] = ["parts": [["text": system]]] }
        case .openAICompatible: throw TranslationError.malformed
        }
        ServiceReasoning.apply(to: &body, configuration: input.configuration)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw TranslationError.malformed }
        if let error = object["error"], !(error is NSNull) { throw ServiceAPIError.mapped(error) }
        return object
    }
    static func geminiText(_ candidate: [String: Any]?) -> String {
        let content = candidate?["content"] as? [String: Any]
        return (content?["parts"] as? [[String: Any]] ?? []).filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
    }
    static func checkFinish(_ reason: String?) throws {
        if ["MAX_TOKENS", "max_tokens", "length"].contains(reason ?? "") { throw TranslationError.incomplete }
        if ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "content_filter", "refusal"].contains(reason ?? "") {
            throw TranslationError.transport(.key("theServiceCouldNotProcessThisContent"))
        }
    }
}

/// AsyncBytes.lines 会跳过空行；SSE 必须保留空行才能正确分隔事件。
/// 在完整行形成后解码 UTF-8，避免网络分片截断多字节字符。
struct ServiceStreamLineDecoder {
    private var buffer: [UInt8] = []
    private var skipLF = false
    private var firstLine = true

    mutating func byte(_ byte: UInt8) throws -> String? {
        if skipLF {
            skipLF = false
            if byte == 10 { return nil }
        }
        if byte == 10 || byte == 13 {
            skipLF = byte == 13
            return try takeLine()
        }
        buffer.append(byte)
        return nil
    }

    mutating func finish() throws -> String? {
        buffer.isEmpty ? nil : try takeLine()
    }

    private mutating func takeLine() throws -> String {
        guard var line = String(bytes: buffer, encoding: .utf8) else { throw TranslationError.malformed }
        buffer.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
        }
        return line
    }
}

struct ServiceStreamDecoder {
    let style: ServiceAPIStyle
    private(set) var completed = false
    private var dataLines: [String] = []
    init(style: ServiceAPIStyle) { self.style = style }
    mutating func line(_ line: String) throws -> String {
        if line.isEmpty { return try flush() }
        if line.hasPrefix("data:") {
            var payload = String(line.dropFirst(5))
            if payload.hasPrefix(" ") { payload.removeFirst() }
            dataLines.append(payload)
        }
        return ""
    }
    mutating func flush() throws -> String {
        guard !dataLines.isEmpty else { return "" }
        let payload = dataLines.joined(separator: "\n"); dataLines=[]
        if payload == "[DONE]" { completed=true; return "" }
        let json = try ServiceWire.object(Data(payload.utf8))
        switch style {
        case .openAICompatible:
            // 部分服务的最后一帧只有 usage，不能当成损坏的正文。
            guard let first = (json["choices"] as? [[String: Any]])?.first else { return "" }
            let reason = first["finish_reason"] as? String
            try ServiceWire.checkFinish(reason)
            if reason != nil { completed=true }
            return (first["delta"] as? [String: Any])?["content"] as? String ?? ""
        case .anthropic:
            switch json["type"] as? String {
            case "content_block_start":
                let block = json["content_block"] as? [String: Any]
                return block?["type"] as? String == "text" ? (block?["text"] as? String ?? "") : ""
            case "content_block_delta":
                let delta = json["delta"] as? [String: Any]
                return delta?["type"] as? String == "text_delta" ? (delta?["text"] as? String ?? "") : ""
            case "message_delta":
                try ServiceWire.checkFinish((json["delta"] as? [String: Any])?["stop_reason"] as? String); return ""
            case "message_stop": completed=true; return ""
            case "error": throw TranslationError.transport(.key("theServiceReturnedAnErrorTryAgain"))
            default: return ""
            }
        case .openAIResponses:
            switch json["type"] as? String {
            case "response.output_text.delta": return json["delta"] as? String ?? ""
            case "response.completed": completed=true; return ""
            case "response.failed", "error": throw TranslationError.transport(.key("theServiceReturnedAnErrorTryAgain"))
            case "response.incomplete": throw TranslationError.incomplete
            default: return ""
            }
        case .gemini:
            let candidate = (json["candidates"] as? [[String: Any]])?.first
            let reason = candidate?["finishReason"] as? String
            try ServiceWire.checkFinish(reason)
            if reason != nil { completed=true }
            if json["promptFeedback"] != nil, candidate == nil { throw TranslationError.transport(.key("theServiceCouldNotProcessThisContent")) }
            return ServiceWire.geminiText(candidate)
        }
    }
}

extension URL {
    /// 服务地址验证与流式请求都接受末尾斜线，保留单独的根路径。
    var servicePath: String {
        let decoded = path(percentEncoded: false)
        guard let last = decoded.lastIndex(where: { $0 != "/" }) else {
            return decoded.isEmpty ? "" : "/"
        }
        return String(decoded[...last])
    }
}
