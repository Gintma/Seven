import Foundation

/// Reflow can add or remove Markdown markers before a selection or reading position.
struct ResultTextAnchor {
    let offset: Int
    let text: String

    init(in source: NSString, range: NSRange) {
        self.offset = range.location
        self.text = source.substring(with: range)
    }

    func range(in destination: NSString) -> NSRange {
        let offset = min(offset, destination.length)
        guard !text.isEmpty, offset < destination.length else { return NSRange(location: offset, length: 0) }
        let length = (text as NSString).length
        let start = max(0, offset - 2048)
        let end = min(destination.length, offset + 2048 + length)
        let leftEnd = min(end, offset + length)
        let left = destination.range(of: text, options: [.backwards, .literal],
                                     range: NSRange(location: start, length: leftEnd - start))
        let right = destination.range(of: text, options: .literal,
                                      range: NSRange(location: offset, length: end - offset))
        if left.location != NSNotFound && (right.location == NSNotFound || offset - left.location <= right.location - offset) {
            return left
        }
        if right.location != NSNotFound { return right }

        return destination.rangeOfComposedCharacterSequences(for: NSRange(
            location: offset, length: min(length, destination.length - offset)
        ))
    }
}
