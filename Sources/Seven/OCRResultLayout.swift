import Foundation
import Vision

/// Formatting only reflows the current text; geometry metadata is used only for unedited recognition results.
enum OCRResultLayout: String, CaseIterable {
    case smart, merged, lines
    static let preferenceKey = "ocr.layout.v1"
    var title: String { switch self { case .smart: return L10n.text("smartLayout"); case .merged: return L10n.text("mergeLineBreaks"); case .lines: return L10n.text("keepLineBreaks") } }

    func apply(to text: String, lines: [OCRTextLine] = []) -> String {
        if self == .lines { return text }
        let ordered = self == .smart && lines.map(\.text).joined(separator: "\n") == text ? Self.readingOrder(lines) : lines
        let rows = ordered != lines ? ordered.map(\.text) : text.components(separatedBy: .newlines)
        let lines = ordered
        if self == .merged {
            return rows.reduce("") { Self.join($0, $1.trimmingCharacters(in: .whitespaces)) }
        }
        var output = ""
        for (index, row) in rows.enumerated() {
            guard index > 0 else { output = row; continue }
            let previous = rows[index - 1]
            let blank = row.trimmingCharacters(in: .whitespaces).isEmpty || previous.trimmingCharacters(in: .whitespaces).isEmpty
            var separate = blank || Self.isStructured(row) || Self.isStructured(previous)
            if lines.count == rows.count {
                let a = lines[index - 1].boundingBox, b = lines[index].boundingBox
                let height = max(a.height, b.height)
                // Vision uses a bottom-left origin. Do not merge across columns or wraps back to the top; preserve large line gaps, indentation, and short headings.
                separate = separate || b.midY >= a.midY || a.minY - b.maxY > height * 0.8
                    || abs(a.minX - b.minX) > height * 1.5 || a.height > b.height * 1.25
                    || (a.width < b.width * 0.65 && Self.endsSentence(previous))
            } else {
                // After manual edits there are no reliable line boxes; conservatively keep sentence-ending line breaks to avoid rewriting paragraphs.
                separate = separate || Self.endsSentence(previous)
            }
            output = separate ? output + "\n" + row : Self.join(output, row.trimmingCharacters(in: .whitespaces))
        }
        return output
    }

    /// Split into columns only when a blank gutter spans all line boxes; keep ambiguous layouts like multi-column headings in their original order.
    private static func readingOrder(_ lines: [OCRTextLine]) -> [OCRTextLine] {
        guard lines.count >= 4 else { return lines }
        let sorted = lines.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        let heights = lines.map { $0.boundingBox.height }.sorted()
        let gap = heights[heights.count / 2] * 2
        for split in 2...(sorted.count - 2) {
            let left = Array(sorted[..<split]), right = Array(sorted[split...])
            let edge = left.map { $0.boundingBox.maxX }.max() ?? 1
            if let start = right.map({ $0.boundingBox.minX }).min(), start - edge > gap {
                return readingOrder(left).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                    + readingOrder(right).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            }
        }
        return lines
    }

    private static func isStructured(_ text: String) -> Bool {
        if text.contains("\t") || text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("/") { return true }
        if text.hasPrefix("\t") || text.hasPrefix("  ") { return true }
        return text.range(of: #"^\s*(?:[-*•·]|\d+[.)、]|[一二三四五六七八九十]+[、.])\s*"#, options: .regularExpression) != nil
    }
    private static func endsSentence(_ text: String) -> Bool {
        text.last.map { "。！？.!?：:".contains($0) } ?? false
    }
    private static func join(_ a: String, _ b: String) -> String {
        guard let last = a.last else { return b }
        guard let first = b.first else { return a }
        if last.isWhitespace || first.isWhitespace { return a + b }
        func eastAsian(_ c: Character) -> Bool {
            c.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
        }
        // Do not guess hyphenated word breaks; join CJK directly and insert a space between Latin words.
        return a + (eastAsian(last) || eastAsian(first) ? "" : " ") + b
    }
}

enum OCRRecognitionLanguages {
    static let preferenceKey = "ocr.recognitionLanguage.v1"
    static func supported() -> [String] {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }
    static func name(_ code: String) -> String {
        let catalog = LanguageCatalog.codes.first { equivalent($0, code) }
        return catalog.map(LanguageCatalog.name) ?? L10n.locale.localizedString(forIdentifier: code) ?? code
    }
    static func equivalent(_ a: String, _ b: String) -> Bool {
        let lhs = Locale.Language(identifier: a), rhs = Locale.Language(identifier: b)
        return lhs.languageCode == rhs.languageCode && lhs.script == rhs.script
    }
    static func ordered(_ supported: [String], common: [String]) -> (common: [String], other: [String]) {
        var preferred: [String] = []
        for code in common {
            if let match = supported.first(where: { equivalent($0, code) }), !preferred.contains(match) { preferred.append(match) }
        }
        return (preferred, supported.filter { !preferred.contains($0) })
    }
}
