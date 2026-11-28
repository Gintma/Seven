import AppKit

/// Reusable segmented control preserving NSSegmentedControl click, keyboard, and accessibility behavior, supporting text, icons, or both.
final class SlidingSegmentedControl: NSSegmentedControl, ThemeApplying {
    private var palette = ThemePalette.system
    enum WidthMode { case equal, content }
    enum ImageDecoration { case none, filled, outlined }
    private var imageDecorations: [Int: ImageDecoration] = [:]
    func setImageDecoration(_ decoration: ImageDecoration, forSegment segment: Int) {
        imageDecorations[segment] = decoration
        content.needsDisplay = true
    }
    var imageSize: CGFloat = Design.Segmented.iconSize {
        didSet { invalidateIntrinsicContentSize(); needsLayout = true; content.needsDisplay = true }
    }
    var onSelectionChange: ((Int) -> Void)?
    /// Inset between the selection pill and the outer border; text and icon padding are controlled independently by size.
    var thumbInset: CGFloat = Design.Segmented.thumbInset {
        didSet {
            selection.radius = max(0, size.radius - thumbInset)
            needsLayout = true
        }
    }
    var size: Design.Segmented.Size = .regular {
        didSet {
            invalidateIntrinsicContentSize(); needsLayout = true; needsDisplay = true
            selection.radius = max(0, size.radius - thumbInset)
            content.needsDisplay = true
        }
    }
    var widthMode: WidthMode = .equal { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    private let selection = SegmentSurface(frame: .zero)
    private let content = SegmentContent()
    private var lastSelection = -1
    private var selectionTarget = CGRect.null
    private var requestedWidths: [Int: CGFloat] = [:]
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        content.owner = self
        addSubview(selection); addSubview(content)
        ThemeManager.shared.register(self)
    }
    required init?(coder: NSCoder) { nil }
    convenience init(size: Design.Segmented.Size) {
        self.init(frame: .zero)
        self.size = size
    }
    override func setAccessibilityLabel(_ label: String?) {
        super.setAccessibilityLabel(label)
        // NSSegmentedControl's actual radioGroup is exposed by its cell and does not inherit the outer control's title.
        cell?.setAccessibilityLabel(label)
    }
    override func setWidth(_ width: CGFloat, forSegment segment: Int) {
        requestedWidths[segment] = width
        super.setWidth(width, forSegment: segment)
        invalidateIntrinsicContentSize(); needsLayout = true
    }
    override func setLabel(_ label: String, forSegment segment: Int) {
        super.setLabel(label, forSegment: segment)
        invalidateIntrinsicContentSize(); needsLayout = true; content.needsDisplay = true
    }
    override func setImage(_ image: NSImage?, forSegment segment: Int) {
        super.setImage(image, forSegment: segment)
        invalidateIntrinsicContentSize(); needsLayout = true; content.needsDisplay = true
    }
    override func setEnabled(_ enabled: Bool, forSegment segment: Int) {
        super.setEnabled(enabled, forSegment: segment)
        content.needsDisplay = true
    }
    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        selection.applyTheme(palette)
        needsDisplay = true
        content.needsDisplay = true
    }

    private var animatesSelectionChanges = true
    override var selectedSegment: Int { didSet { updateSelection(animated: animatesSelectionChanges) } }
    /// Restoring preferences skips selection animation; setting the same value does not interrupt an in-flight user slide.
    func setSelectedSegment(_ index: Int, animated: Bool) {
        guard selectedSegment != index else { return }
        animatesSelectionChanges = animated
        if !animated { selection.layer?.removeAllAnimations() }
        selectedSegment = index
        animatesSelectionChanges = true
    }
    override var isEnabled: Bool { didSet { content.needsDisplay = true } }
    override var intrinsicContentSize: NSSize {
        NSSize(width: widths.reduce(0, +), height: size.height)
    }
    private var widths: [CGFloat] {
        let natural = (0..<segmentCount).map { index -> CGFloat in
            let text = (label(forSegment: index) ?? "") as NSString
            let textWidth = text.length > 0 ? text.size(withAttributes: [.font: Design.Segmented.font]).width : 0
            let iconWidth = image(forSegment: index) == nil ? 0 : imageSize
            let gap = textWidth > 0 && iconWidth > 0 ? Design.Segmented.contentGap : 0
            return max(requestedWidths[index] ?? 0, max(size.height, textWidth + iconWidth + gap + size.horizontalInset * 2))
        }
        return widthMode == .equal ? natural.map { _ in natural.max() ?? size.height } : natural
    }
    func frameForSegment(_ index: Int) -> CGRect {
        let sizes = widths
        guard sizes.indices.contains(index) else { return .zero }
        return CGRect(x: sizes.prefix(index).reduce(0, +), y: 0, width: sizes[index], height: bounds.height)
    }
    override func layout() {
        super.layout()
        // Keep system hit-test regions synced with the custom appearance to prevent click misalignment when sizing to content.
        let sizes = widths
        for index in sizes.indices { super.setWidth(sizes[index], forSegment: index) }
        content.frame = bounds
        // The native cell may update selection and trigger layout before sending its action; do not snap to the end position early here.
        // Initial layout, size changes on the same segment, and explicit restores are still positioned directly via updateSelection's conditions.
        updateSelection(animated: true)
    }
    private func updateSelection(animated: Bool) {
        content.needsDisplay = true
        selection.isHidden = selectedSegment < 0 || selectedSegment >= segmentCount
        guard !selection.isHidden else { selectionTarget = .null; lastSelection = -1; return }
        let frame = frameForSegment(selectedSegment).insetBy(dx: thumbInset, dy: thumbInset)
        guard frame != selectionTarget else { return }
        selectionTarget = frame
        let animate = animated && window != nil && lastSelection >= 0 && lastSelection != selectedSegment && !Design.Motion.reduced
        lastSelection = selectedSegment
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Design.Motion.fast
                selection.animator().frame = frame
            }
        } else { selection.frame = frame }
    }
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        updateSelection(animated: true)
        onSelectionChange?(selectedSegment)
        return super.sendAction(action, to: target)
    }
    override func draw(_ dirtyRect: NSRect) {
        palette.segmentFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: size.radius, yRadius: size.radius).fill()
    }
    fileprivate func drawContent() {
        for index in 0..<segmentCount {
            let rect = frameForSegment(index)
            let label = label(forSegment: index) ?? ""
            let textSize = (label as NSString).size(withAttributes: [.font: Design.Segmented.font])
            let icon = image(forSegment: index)
            let iconWidth = icon == nil ? 0 : imageSize
            let gap = icon != nil && !label.isEmpty ? Design.Segmented.contentGap : 0
            let x = rect.midX - (iconWidth + gap + (label.isEmpty ? 0 : textSize.width)) / 2
            let enabledInk = palette.isSystem || index == selectedSegment ? palette.ink : palette.inkSecondary
            let ink = isEnabled && isEnabled(forSegment: index) ? enabledInk : palette.disabledInk
            if let icon {
                let decoration = imageDecorations[index] ?? .none
                let glyphInk: NSColor
                if decoration != .none {
                    let badge = backingAlignedRect(CGRect(x: x - Design.Segmented.symbolBadgeInset,
                        y: rect.midY - Design.Segmented.symbolBadgeHeight / 2,
                        width: iconWidth + Design.Segmented.symbolBadgeInset * 2,
                        height: Design.Segmented.symbolBadgeHeight), options: .alignAllEdgesNearest)
                    let path = NSBezierPath(roundedRect: badge, xRadius: Design.Segmented.symbolBadgeRadius, yRadius: Design.Segmented.symbolBadgeRadius)
                    ink.setFill(); ink.setStroke()
                    if decoration == .filled { path.fill() } else {
                        path.lineWidth = Design.Segmented.symbolBadgeLineWidth; path.stroke()
                    }
                    glyphInk = decoration == .filled ? palette.surfaceRaised : ink
                } else { glyphInk = ink }
                let configured = icon.withSymbolConfiguration(.preferringMonochrome()) ?? icon
                let ratio = min(iconWidth / max(1, configured.size.width), iconWidth / max(1, configured.size.height))
                let size = CGSize(width: configured.size.width * ratio, height: configured.size.height * ratio)
                let target = backingAlignedRect(CGRect(x: x + (iconWidth - size.width) / 2,
                    y: rect.midY - size.height / 2, width: size.width, height: size.height), options: .alignAllEdgesNearest)
                // Keep the SF vector representation so AppKit rasterizes at the current display scale instead of stretching a low-resolution CGImage into a mask.
                let context = NSGraphicsContext.current?.cgContext
                context?.saveGState()
                context?.beginTransparencyLayer(auxiliaryInfo: nil)
                configured.draw(in: target)
                glyphInk.setFill(); target.fill(using: .sourceIn)
                context?.endTransparencyLayer()
                context?.restoreGState()
            }
            if !label.isEmpty {
                (label as NSString).draw(at: CGPoint(x: x + iconWidth + gap, y: rect.midY - textSize.height / 2), withAttributes: [.font: Design.Segmented.font, .foregroundColor: ink])
            }
        }
    }
}

private final class SegmentSurface: NSView, ThemeApplying {
    private var palette = ThemePalette.system

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        needsDisplay = true
    }
    var radius = Design.Segmented.radius - Design.Segmented.thumbInset {
        didSet { needsDisplay = true }
    }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        palette.segmentSelectedFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}
private final class SegmentContent: NSView {
    weak var owner: SlidingSegmentedControl?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { owner?.drawContent() }
}
