import AppKit

/// 编辑旧文字时，把其后创建的图层绘制在原生文本编辑器之上，保持文档层级。
@MainActor final class ScreenshotEditorLayersOverlay: NSView {
    private let drawContent: () -> Void
    init(draw: @escaping () -> Void) {
        drawContent = draw
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { drawContent() }
}
