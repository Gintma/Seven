import Foundation

/// 写回后优先核验插入范围；不要求富文本编辑器的整框 AXValue 等于纯文本拼接结果。
enum InputReplacementWriteVerification {
    static func matches(translated: String, before: InputReplacementSnapshot, wholeInput: Bool,
                        insertedText: String?, currentValue: String?, currentDocument: String?) -> Bool {
        let normalized = normalize(translated)
        guard !normalized.isEmpty else { return false }
        // 文档范围 API 与原生选区在相同坐标系中，能直接确认目标位置的文字。
        if let insertedText, normalize(insertedText) == normalized { return true }
        if wholeInput {
            return [currentValue, currentDocument].compactMap { $0 }.contains { normalize($0) == normalized }
        }
        // 只有没有范围文本可用时，才尝试旧的整框拼接校验。
        guard let expected = before.replacing(with: translated) else { return false }
        return [currentValue, currentDocument].compactMap { $0 }.contains { normalize($0) == normalize(expected) }
    }

    private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
