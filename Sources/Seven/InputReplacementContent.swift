import Foundation

/// 区分确认空白、可读取正文与真实读取失败；独立正文优先于占位提示。
enum InputReplacementContent {
    static func resolve(value: String?, characterCount: Int?, placeholder: String?, documentText: String?) throws -> String {
        if let characterCount, characterCount < 0 { throw InputReplacementError.unreadable }
        if characterCount == 0 { throw InputReplacementError.empty }
        if characterCount == nil, let placeholder, !placeholder.isEmpty, value == placeholder,
           documentText == nil || documentText == placeholder {
            throw InputReplacementError.empty
        }
        // 范围文本来自真实文档，优先于可能带占位提示的 AXValue。
        if let documentText {
            if documentText.isEmpty, let characterCount, characterCount > 0 {
                throw InputReplacementError.unreadable
            }
            guard !documentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw InputReplacementError.empty
            }
            return documentText
        }
        guard let value else { throw InputReplacementError.unreadable }
        if value.isEmpty, let characterCount, characterCount > 0 { throw InputReplacementError.unreadable }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InputReplacementError.empty }
        return value
    }
}
