import AppKit

/// The outer document reserves one selectable glyph for an overflowing table.
@MainActor
final class ResultMarkdownWideTable: NSObject {
    static let attribute = NSAttributedString.Key("SevenMarkdownWideTable")

    let blockIndex: Int
    let content: NSAttributedString
    let plainText: String
    let width: CGFloat
    let height: CGFloat

    init(blockIndex: Int, content: NSAttributedString, plainText: String, width: CGFloat) {
        self.blockIndex = blockIndex
        self.content = content
        self.plainText = plainText
        self.width = width

        let storage = NSTextStorage(attributedString: content)
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let extra = layout.extraLineFragmentRect
        height = ceil(extra.isEmpty ? used.maxY : min(used.maxY, extra.minY))
        super.init()
    }

    func attachment(viewportWidth: CGFloat) -> NSMutableAttributedString {
        let attachment = NSTextAttachment()
        // Keep a single glyph in the outer text storage for layout and cross-block selection.
        attachment.image = NSImage(size: NSSize(width: viewportWidth.rounded(.down), height: height))
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(Self.attribute, value: self, range: NSRange(location: 0, length: result.length))
        return result
    }
}

@MainActor
final class ResultMarkdownTableScrollView: NSScrollView {
    let text = StreamingResultTextView()
    private var currentContent: NSAttributedString?

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = false
        scrollerStyle = .overlay
        autohidesScrollers = true
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none

        text.drawsBackground = false
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.isAutomaticLinkDetectionEnabled = false
        text.copiesSelectionAsPlainText = true
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        documentView = text
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ table: ResultMarkdownWideTable, frame: NSRect, delegate: NSTextViewDelegate?) {
        let previousX = contentView.bounds.minX
        if self.frame != frame { self.frame = frame }
        let size = NSSize(width: table.width, height: table.height)
        if text.frame.size != size {
            text.frame.size = size
            text.textContainer?.containerSize = NSSize(width: table.width, height: CGFloat.greatestFiniteMagnitude)
        }
        text.delegate = delegate
        if currentContent != table.content {
            currentContent = table.content
            text.replace(with: table.content, preservingSelection: true)
        }
        let x = min(previousX, max(0, table.width - contentSize.width))
        if contentView.bounds.origin != NSPoint(x: x, y: 0) {
            contentView.scroll(to: NSPoint(x: x, y: 0))
            reflectScrolledClipView(contentView)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let x = event.scrollingDeltaX
        let y = event.scrollingDeltaY
        let delta: CGFloat
        if abs(x) > abs(y) {
            delta = x
        } else if event.modifierFlags.contains(.shift), y != 0 {
            delta = y
        } else {
            // Vertical wheel input continues to move the surrounding translation panel.
            superview?.enclosingScrollView?.scrollWheel(with: event)
            return
        }

        let speed = event.hasPreciseScrollingDeltas ? 1 : horizontalLineScroll
        let maximum = max(0, (documentView?.frame.width ?? 0) - contentSize.width)
        let offset = min(max(0, contentView.bounds.minX - delta * speed), maximum)
        contentView.scroll(to: NSPoint(x: offset, y: 0))
        reflectScrolledClipView(contentView)
    }
}
