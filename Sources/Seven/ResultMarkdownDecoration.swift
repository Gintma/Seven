import AppKit

@MainActor
enum ResultMarkdownDecoration {
    static func draw(in view: NSTextView, dirtyRect: NSRect, palette: ThemePalette) {
        guard let storage = view.textStorage, storage.length > 0,
              let layout = view.layoutManager, let container = view.textContainer else { return }
        let origin = view.textContainerOrigin
        let visible = layout.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let characters = layout.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
        guard characters.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: storage.length)

        func lines(_ range: NSRange) -> NSRect? {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return nil }
            let first = layout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let last = layout.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            return first.union(last).offsetBy(dx: origin.x, dy: origin.y)
        }

        var position = characters.location
        while position < NSMaxRange(characters) {
            var codeRange = NSRange()
            let code = storage.attribute(ResultMarkdownRenderer.codeBlockAttribute, at: position,
                                         longestEffectiveRange: &codeRange, in: fullRange)
            if code != nil, let rect = lines(codeRange) {
                let para = storage.attribute(.paragraphStyle, at: codeRange.location, effectiveRange: nil) as? NSParagraphStyle
                let x = origin.x + (para?.headIndent ?? Design.Space.s) - Design.Space.s
                let background = NSRect(x: x, y: rect.minY - 2, width: max(0, view.bounds.maxX - x), height: rect.height + 4)
                let clipped = background.intersection(view.bounds)
                if !clipped.isEmpty {
                    palette.surfaceInset.setFill()
                    NSBezierPath(roundedRect: clipped, xRadius: Design.Radius.control, yRadius: Design.Radius.control).fill()
                }
            }
            position = NSMaxRange(codeRange)
        }

        palette.separator.setFill()
        storage.enumerateAttribute(ResultMarkdownRenderer.ruleAttribute, in: characters) { value, range, _ in
            guard value != nil, let line = lines(range) else { return }
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let x = origin.x + (style?.firstLineHeadIndent ?? 0)
            NSBezierPath(rect: NSRect(x: x, y: floor(line.midY), width: max(0, view.bounds.maxX - x), height: 1)).fill()
        }

        var rails: [Int: NSRect] = [:]
        var completed: [NSRect] = []
        storage.enumerateAttribute(ResultMarkdownRenderer.quoteDepthAttribute, in: characters) { value, range, _ in
            let depth = value as? Int ?? 0
            for level in rails.keys.filter({ $0 >= depth }) {
                if let rail = rails.removeValue(forKey: level) { completed.append(rail) }
            }
            guard depth > 0, let line = lines(range) else { return }
            for level in 0..<depth {
                let rect = NSRect(x: origin.x + CGFloat(level) * Design.Space.m + 2, y: line.minY, width: 2, height: line.height)
                rails[level] = rails[level]?.union(rect) ?? rect
            }
        }
        for rail in completed + rails.values {
            NSBezierPath(roundedRect: rail, xRadius: 1, yRadius: 1).fill()
        }
    }
}
