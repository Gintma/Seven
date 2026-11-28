import AppKit

/// While editing an older text annotation, renders newer layers above the native text editor to preserve document z-order.
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
