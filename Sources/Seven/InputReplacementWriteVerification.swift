import Foundation

/// Verifies the inserted range first after writeback; does not require a rich-text editor's full AXValue to match plain-text concatenation.
enum InputReplacementWriteVerification {
    static func matches(translated: String, before: InputReplacementSnapshot, wholeInput: Bool,
                        insertedText: String?, currentValue: String?, currentDocument: String?) -> Bool {
        let normalized = normalize(translated)
        guard !normalized.isEmpty else { return false }
        // Document range APIs share the same coordinate space as native selections and can directly verify text at the target range.
        if let insertedText, normalize(insertedText) == normalized { return true }
        if wholeInput {
            return [currentValue, currentDocument].compactMap { $0 }.contains { normalize($0) == normalized }
        }
        // Fall back to legacy whole-field concatenation verification only when range text is unavailable.
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
