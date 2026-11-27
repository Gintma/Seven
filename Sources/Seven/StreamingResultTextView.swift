import AppKit
import QuartzCore

/// Network text is queued independently of the visible, selectable text storage.
@MainActor
final class StreamingResultTextView: NSTextView {
    static let themeTokenAttribute = NSAttributedString.Key("SevenThemeToken")
    private var palette = ThemePalette.system
    var copiesSelectionAsPlainText = false
    var usesSimpleTextCursor = false
    private var drawsMarkdownDecorations = false
    private var containsWideTables = false
    private var wideTables: [Int: ResultMarkdownTableScrollView] = [:]

    override func draw(_ dirtyRect: NSRect) {
        if drawsMarkdownDecorations { ResultMarkdownDecoration.draw(in: self, dirtyRect: dirtyRect, palette: palette) }
        super.draw(dirtyRect)
    }

    override func layout() {
        super.layout()
        layoutWideTables()
    }

    private func layoutWideTables() {
        if !containsWideTables, wideTables.isEmpty { return }
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return }
        layout.ensureLayout(for: container)
        var active = Set<Int>()
        storage.enumerateAttribute(ResultMarkdownWideTable.attribute, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let table = value as? ResultMarkdownWideTable else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let origin = textContainerOrigin
            let frame = NSRect(x: rect.minX + origin.x, y: rect.minY + origin.y,
                               width: max(0, bounds.width - rect.minX - origin.x), height: table.height)
            guard frame.width > 0, frame.height > 0 else { return }
            let tableView = wideTables[table.blockIndex] ?? ResultMarkdownTableScrollView()
            if tableView.superview == nil { addSubview(tableView) }
            tableView.apply(table, frame: frame, delegate: delegate)
            wideTables[table.blockIndex] = tableView
            active.insert(table.blockIndex)
        }
        for index in wideTables.keys.filter({ !active.contains($0) }) {
            wideTables.removeValue(forKey: index)?.removeFromSuperview()
        }
    }

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        applyThemeSelection(palette)
        recolor(textStorage, using: palette)
        recolor(pending, using: palette)
        if let range = hoveredLinkRange {
            removeHoveredLinkAttributes(in: range)
            applyHoveredLinkAttributes(in: range)
        }
    }

    private func recolor(_ text: NSMutableAttributedString?, using palette: ThemePalette) {
        guard let text, text.length > 0 else { return }
        text.beginEditing()
        text.enumerateAttribute(Self.themeTokenAttribute, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let key = value as? String, let token = ThemeToken(rawValue: key) else { return }
            text.addAttribute(.foregroundColor, value: palette[token], range: range)
        }
        text.endEditing()
    }

    private let pending = NSMutableAttributedString()
    private var pendingOffset = 0
    private var revealsInBatches = false
    private var revealTimer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var credit: Double = 0
    private(set) var isRevealing = false
    var onVisibleTextChange: (() -> Void)?
    static let arrowCursorAttribute = NSAttributedString.Key("SevenResultArrowCursor")
    var arrowCursorRects: [CGRect] = [] {
        didSet { if oldValue != arrowCursorRects { window?.invalidateCursorRects(for: self) } }
    }
    private var cursorTracking: NSTrackingArea?
    private var hoveredLinkRange: NSRange?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        if window == nil { updateHoveredLink(nil) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let range = hoveredLinkRange else { return }
        removeHoveredLinkAttributes(in: range)
        applyHoveredLinkAttributes(in: range)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        cursorTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); cursorUpdate(with: event) }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); cursorUpdate(with: event) }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateHoveredLink(nil)
    }

    private func updateHoveredLink(_ range: NSRange?) {
        guard range != hoveredLinkRange else { return }
        if let old = hoveredLinkRange { removeHoveredLinkAttributes(in: old) }
        hoveredLinkRange = range
        if let range { applyHoveredLinkAttributes(in: range) }
    }

    private func removeHoveredLinkAttributes(in range: NSRange) {
        layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
        layoutManager?.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
    }

    private func applyHoveredLinkAttributes(in range: NSRange) {
        let color = textStorage?.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
            ?? palette.link
        var resolved = color
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
        layoutManager?.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: resolved],
                                             forCharacterRange: range)
    }

    override func cursorUpdate(with event: NSEvent) {
        if usesSimpleTextCursor && !renderingSuspended { NSCursor.iBeam.set(); return }
        let point = convert(event.locationInWindow, from: nil)
        guard !renderingSuspended, !arrowCursorRects.contains(where: { $0.contains(point) }),
              let manager = layoutManager, let container = textContainer else { updateHoveredLink(nil); NSCursor.arrow.set(); return }
        let local = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: local, in: container)
        guard glyph < manager.numberOfGlyphs,
              manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else {
            updateHoveredLink(nil); NSCursor.arrow.set(); return
        }
        let index = manager.characterIndexForGlyph(at: glyph)
        var range = NSRange(location: 0, length: 0)
        if textStorage?.attribute(.link, at: index, effectiveRange: &range) != nil {
            updateHoveredLink(range)
            NSCursor.pointingHand.set()
        } else {
            updateHoveredLink(nil)
            let arrow = textStorage?.attribute(Self.arrowCursorAttribute, at: index, effectiveRange: nil) != nil
            (arrow ? NSCursor.arrow : .iBeam).set()
        }
    }

    override func resetCursorRects() {
        if usesSimpleTextCursor { addCursorRect(bounds, cursor: .iBeam); return }
        addCursorRect(bounds, cursor: .arrow)
        guard let manager = layoutManager, let container = textContainer else { return }
        _ = manager.glyphRange(for: container)
        textStorage?.enumerateAttributes(in: NSRange(location: 0, length: textStorage?.length ?? 0)) { attributes, characters, _ in
            let cursor: NSCursor
            if attributes[.link] != nil { cursor = .pointingHand }
            else if attributes[Self.arrowCursorAttribute] != nil { return }
            else { cursor = .iBeam }
            let glyphs = manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                var pieces = [rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)]
                for excluded in self.arrowCursorRects {
                    pieces = pieces.flatMap { original -> [CGRect] in
                        let overlap = original.intersection(excluded)
                        guard !overlap.isNull, !overlap.isEmpty else { return [original] }
                        return [CGRect(x: original.minX, y: original.minY, width: overlap.minX-original.minX, height: original.height),
                                CGRect(x: overlap.maxX, y: original.minY, width: original.maxX-overlap.maxX, height: original.height),
                                CGRect(x: overlap.minX, y: original.minY, width: overlap.width, height: overlap.minY-original.minY),
                                CGRect(x: overlap.minX, y: overlap.maxY, width: overlap.width, height: original.maxY-overlap.maxY)].filter { !$0.isEmpty }
                    }
                }
                for piece in pieces { self.addCursorRect(piece, cursor: cursor) }
            }
        }
        for rect in arrowCursorRects { addCursorRect(rect, cursor: .arrow) }
    }
    var renderingSuspended = false {
        didSet {
            if renderingSuspended && !oldValue { updateHoveredLink(nil); stopTimer() }
            if !renderingSuspended && oldValue { startTimerIfNeeded() }
        }
    }

    func append(_ value: NSAttributedString, progressively: Bool, batches: Bool = false) {
        guard !renderingSuspended, value.length > 0 else { return }
        if batches || revealsInBatches {
            revealsInBatches = true
            pending.append(value)
            startTimerIfNeeded()
            return
        }
        guard progressively, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            flushPending(notify: false)
            textStorage?.append(value)
            onVisibleTextChange?()
            return
        }
        pending.append(value)
        startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        guard !renderingSuspended, revealTimer == nil, pendingOffset < pending.length else { return }
        isRevealing = true
        lastTick = CACurrentMediaTime()
        credit = 0
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.revealNextFrame()
            }
        }
        revealTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func replace(with value: NSAttributedString, preservingSelection: Bool = false, markdown: Bool = false) {
        let oldText = string as NSString
        let anchors = preservingSelection ? selectedRanges.compactMap { item -> ResultTextAnchor? in
            let range = item.rangeValue
            guard range.length > 0, NSMaxRange(range) <= oldText.length else { return nil }
            return ResultTextAnchor(in: oldText, range: range)
        } : []
        updateHoveredLink(nil)
        stopTimer()
        pending.setAttributedString(NSAttributedString(string: ""))
        pendingOffset = 0
        revealsInBatches = false
        drawsMarkdownDecorations = markdown
        containsWideTables = false
        if markdown {
            value.enumerateAttribute(ResultMarkdownWideTable.attribute, in: NSRange(location: 0, length: value.length)) { attachment, _, stop in
                if attachment != nil { containsWideTables = true; stop.pointee = true }
            }
        }
        textStorage?.setAttributedString(value)
        if containsWideTables || !wideTables.isEmpty { needsLayout = true }
        if !anchors.isEmpty {
            let updated = value.string as NSString
            let ranges = anchors.map { $0.range(in: updated) }.sorted { $0.location < $1.location }
            var disjoint: [NSValue] = []
            for range in ranges where disjoint.last.map({ NSMaxRange($0.rangeValue) <= range.location }) ?? true {
                disjoint.append(NSValue(range: range))
            }
            setSelectedRanges(disjoint, affinity: selectionAffinity, stillSelecting: false)
        }
        window?.invalidateCursorRects(for: self)
        onVisibleTextChange?()
    }

    override func copy(_ sender: Any?) {
        if copiesSelectionAsPlainText {
            _ = copyPlainSelection(to: .general)
        } else {
            super.copy(sender)
        }
    }

    @discardableResult
    func copyPlainSelection(to pasteboard: NSPasteboard) -> Bool {
        let source = string as NSString
        let selections = selectedRanges.compactMap { item -> String? in
            let range = item.rangeValue
            guard range.length > 0, NSMaxRange(range) <= source.length else { return nil }
            guard let textStorage else { return source.substring(with: range) }
            var text = ""
            textStorage.enumerateAttributes(in: range) { attributes, part, _ in
                if let table = attributes[ResultMarkdownWideTable.attribute] as? ResultMarkdownWideTable {
                    text += table.plainText
                } else if attributes[ResultMarkdownRenderer.ruleAttribute] == nil {
                    text += source.substring(with: part)
                }
            }
            return text.replacingOccurrences(of: "\u{2028}", with: "\n")
        }
        guard selections.contains(where: { !$0.isEmpty }) else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(selections.joined(separator: "\n"), forType: .string)
    }

    /// Keep the text line at the viewport edge when a card is restyled or resized.
    func readingAnchor(at y: CGFloat, in document: NSView) -> (() -> CGFloat?)? {
        let point = convert(NSPoint(x: 0, y: y), from: document)
        guard bounds.minY <= point.y, point.y < bounds.maxY,
              let manager = layoutManager, let container = textContainer, manager.numberOfGlyphs > 0 else { return nil }
        let localY = point.y - textContainerOrigin.y
        let glyph = manager.glyphIndex(for: NSPoint(x: 0, y: localY), in: container)
        guard glyph < manager.numberOfGlyphs else { return nil }
        var lineGlyphs = NSRange()
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        let characters = manager.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
        let source = string as NSString
        guard characters.length > 0, NSMaxRange(characters) <= source.length else { return nil }
        let oldLine = source.substring(with: characters)
        let label = oldLine.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
        let needle = String(label.prefix(96))
        let needleRange = (oldLine as NSString).range(of: needle)
        let range = needleRange.location == NSNotFound || needle.isEmpty
            ? source.rangeOfComposedCharacterSequence(at: characters.location)
            : NSRange(location: characters.location + needleRange.location, length: needleRange.length)
        let anchor = ResultTextAnchor(in: source, range: range)
        let inset = localY - line.minY
        return { [weak self, weak document] in
            guard let self, let document, let manager = self.layoutManager,
                  let container = self.textContainer, !self.string.isEmpty else { return nil }
            manager.ensureLayout(for: container)
            let text = self.string as NSString
            let location = min(anchor.range(in: text).location, text.length - 1)
            let glyph = manager.glyphIndexForCharacter(at: location)
            guard glyph < manager.numberOfGlyphs else { return nil }
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return document.convert(NSPoint(x: 0, y: self.textContainerOrigin.y + line.minY + inset), from: self).y
        }
    }

    override func scrollRangeToVisible(_ range: NSRange) {}
    override func scrollToVisible(_ rect: NSRect) -> Bool { false }

    private func revealNextFrame() {
        guard !renderingSuspended, pendingOffset < pending.length else { stopTimer(); return }
        let start = pendingOffset
        let string = pending.mutableString
        if revealsInBatches {
            let end = min(pending.length, pendingOffset + 8192)
            pendingOffset = NSMaxRange(string.rangeOfComposedCharacterSequence(at: end - 1))
        } else {
            let now = CACurrentMediaTime()
            // Stable cadence across chunk boundaries; never dump an entire burst after a stall.
            credit += min(0.04, now - lastTick) * 90
            lastTick = now
            var characters = min(3, Int(credit))
            guard characters > 0 else { return }
            while characters > 0, pendingOffset < pending.length {
                pendingOffset = NSMaxRange(string.rangeOfComposedCharacterSequence(at: pendingOffset))
                characters -= 1
                credit -= 1
            }
        }
        textStorage?.append(pending.attributedSubstring(from: NSRange(
            location: start, length: pendingOffset - start
        )))
        if pendingOffset == pending.length {
            pending.setAttributedString(NSAttributedString(string: ""))
            pendingOffset = 0
            revealsInBatches = false
            stopTimer()
        }
        onVisibleTextChange?()
    }

    private func flushPending(notify: Bool) {
        if pendingOffset < pending.length {
            textStorage?.append(pending.attributedSubstring(from: NSRange(
                location: pendingOffset, length: pending.length - pendingOffset
            )))
        }
        pending.setAttributedString(NSAttributedString(string: ""))
        pendingOffset = 0
        revealsInBatches = false
        stopTimer()
        if notify { onVisibleTextChange?() }
    }

    private func stopTimer() {
        revealTimer?.invalidate()
        revealTimer = nil
        isRevealing = false
    }
}
