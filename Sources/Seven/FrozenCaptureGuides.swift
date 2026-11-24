import AppKit

/// 只作框选辅助，不接收鼠标事件，也不参与截图输出。
final class FrozenCaptureGuidesView: ThemedDrawingView {
    static var shortcuts: [(String, String)] { [("R", L10n.text("capture.previousArea")), ("F", L10n.text("captureFullScreen")), ("⌘", L10n.text("holdToCaptureMultipleWindows")), ("C", L10n.text("copyColorValue")), ("⇧", L10n.text("holdToCaptureASquareArea"))] }
    var shortcuts: [(String, String)] = FrozenCaptureGuidesView.shortcuts { didSet { hint.shortcuts = shortcuts; needsLayout = true } }
    var hintTitle = L10n.text("screenshotShortcuts") { didSet { hint.hintTitle = hintTitle; needsLayout = true } }
    var showsCrosshair=true {didSet{needsDisplay=true}}
    var showsHints=true {didSet{updateHintVisibility()}}
    private var pointer: CGPoint?
    private let hint = FrozenCaptureHintView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        addSubview(hint)
        needsLayout=true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func updatePointer(_ point: CGPoint?) {
        pointer = point; updateHintVisibility(); needsDisplay = true
    }
    private func updateHintVisibility() {
        let avoidance = hint.frame.insetBy(dx: -Design.ScreenshotCapture.hintHoverDistance, dy: -Design.ScreenshotCapture.hintHoverDistance)
        hint.isHidden = !showsHints || (pointer.map(avoidance.contains) ?? false)
    }
    override func layout() {
        super.layout()
        let d = Design.ScreenshotCapture.hintEdgeInset
        let width = min(hint.preferredWidth, max(0, bounds.width - 2 * d))
        hint.frame = CGRect(x: d, y: d, width: width, height: hint.preferredHeight)
        updateHintVisibility()
    }
    override func draw(_ dirtyRect: NSRect) {
        guard showsCrosshair, let pointer, bounds.contains(pointer) else { return }
        theme.captureAccent.setStroke()
        let path = NSBezierPath()
        path.lineWidth = Design.ScreenshotCapture.borderWidth
        path.move(to: CGPoint(x: 0, y: pointer.y)); path.line(to: CGPoint(x: bounds.maxX, y: pointer.y))
        path.move(to: CGPoint(x: pointer.x, y: 0)); path.line(to: CGPoint(x: pointer.x, y: bounds.maxY))
        path.stroke()
    }
}

private final class FrozenCaptureHintView: NSView {
    var shortcuts = FrozenCaptureGuidesView.shortcuts { didSet { updateAccessibility(); needsDisplay = true } }
    var hintTitle = L10n.text("screenshotShortcuts") { didSet { updateAccessibility(); needsDisplay = true } }
    var preferredWidth: CGFloat {
        let style = Design.ScreenshotCapture.self
        let titleWidth = (hintTitle as NSString).size(withAttributes: [.font: style.hintTitleFont]).width
        let labelWidth = shortcuts.map { ($0.1 as NSString).size(withAttributes: [.font: style.hintBodyFont]).width }.max() ?? 0
        return max(style.hintWidth, ceil(2 * style.hintInset + max(titleWidth, style.hintKeySize + style.hintKeyGap + labelWidth)))
    }

    var preferredHeight: CGFloat {
        Design.ScreenshotCapture.hintInset * 2 + Design.ScreenshotCapture.hintTitleHeight + Design.ScreenshotCapture.hintTitleSpacing + CGFloat(shortcuts.count) * Design.ScreenshotCapture.hintRowHeight
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        updateAccessibility()
    }
    private func updateAccessibility() {
        let formatter = ListFormatter()
        formatter.locale = L10n.locale
        let descriptions = shortcuts.map { L10n.format("shortcutDescription", $0.0, $0.1) }
        let list = formatter.string(from: descriptions) ?? descriptions.joined(separator: ", ")
        setAccessibilityLabel(L10n.format("shortcutGuideDescription", hintTitle, list))
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let d = Design.ScreenshotCapture.hintInset
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: Design.ScreenshotCapture.borderWidth / 2, dy: Design.ScreenshotCapture.borderWidth / 2), xRadius: Design.ScreenshotCapture.hintRadius, yRadius: Design.ScreenshotCapture.hintRadius)
        Design.ScreenshotCapture.hintFill.setFill(); background.fill()
        Design.ScreenshotCapture.hintBorder.setStroke(); background.stroke()
        let titleY = bounds.maxY - d - Design.ScreenshotCapture.hintTitleHeight
        (hintTitle as NSString).draw(in: CGRect(x: d, y: titleY, width: bounds.width - d * 2, height: Design.ScreenshotCapture.hintTitleHeight), withAttributes: [.font: Design.ScreenshotCapture.hintTitleFont, .foregroundColor: Design.ScreenshotCapture.hintText])
        for (index, item) in shortcuts.enumerated() {
            let rowTop = titleY - Design.ScreenshotCapture.hintTitleSpacing - CGFloat(index) * Design.ScreenshotCapture.hintRowHeight
            let size = Design.ScreenshotCapture.hintKeySize
            let keyRect = CGRect(x: d, y: rowTop - size, width: size, height: size)
            Design.ScreenshotCapture.hintKeyFill.setFill()
            NSBezierPath(roundedRect: keyRect, xRadius: Design.ScreenshotCapture.hintKeyRadius, yRadius: Design.ScreenshotCapture.hintKeyRadius).fill()
            let keyAttributes: [NSAttributedString.Key: Any] = [.font: Design.ScreenshotCapture.hintKeyFont, .foregroundColor: Design.ScreenshotCapture.hintKeyText]
            let keySize = (item.0 as NSString).size(withAttributes: keyAttributes)
            (item.0 as NSString).draw(at: CGPoint(x: keyRect.midX - keySize.width / 2, y: keyRect.midY - keySize.height / 2), withAttributes: keyAttributes)
            let attributes: [NSAttributedString.Key: Any] = [.font: Design.ScreenshotCapture.hintBodyFont, .foregroundColor: Design.ScreenshotCapture.hintText]
            let textSize = (item.1 as NSString).size(withAttributes: attributes)
            let x = keyRect.maxX + Design.ScreenshotCapture.hintKeyGap
            (item.1 as NSString).draw(in: CGRect(x: x, y: keyRect.midY - textSize.height / 2,
                width: max(0, bounds.width - d - x), height: textSize.height), withAttributes: attributes)
        }
    }
}
