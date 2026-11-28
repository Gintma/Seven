import Foundation

/// Distinguishes confirmed blank, readable content, and real read failures; standalone content takes precedence over placeholders.
enum InputReplacementContent {
    static func resolve(value: String?, characterCount: Int?, placeholder: String?, documentText: String?) throws -> String {
        if let characterCount, characterCount < 0 { throw InputReplacementError.unreadable }
        if characterCount == 0 { throw InputReplacementError.empty }
        if characterCount == nil, let placeholder, !placeholder.isEmpty, value == placeholder,
           documentText == nil || documentText == placeholder {
            throw InputReplacementError.empty
        }
        // Range text comes from the real document and takes precedence over AXValue, which may contain placeholder text.
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
