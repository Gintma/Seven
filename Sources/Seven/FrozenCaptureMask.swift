import AppKit

/// Shared frozen-screen dim mask for region selection, region editing, and window editing; excluded from exported images.
enum FrozenCaptureMask {
    static func draw(background: NSImage, in bounds: CGRect, revealing rects: [CGRect], cornerRadii: CGSize = .zero) {
        background.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        Design.ScreenshotCapture.maskFill.setFill()
        bounds.fill()
        guard !rects.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath()
        path.windingRule = .nonZero
        for rect in rects where !rect.isEmpty { path.append(NSBezierPath(roundedRect: rect, xRadius: cornerRadii.width, yRadius: cornerRadii.height)) }
        path.addClip()
        background.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
    /// Scrolling capture draws only the mask outside the selection without freezing the backdrop; mouse pass-through is controlled by the owning window.
    static func drawOverlay(in bounds: CGRect, revealing rect: CGRect) {
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(rect: rect.intersection(bounds)))
        path.windingRule = .evenOdd
        Design.ScreenshotCapture.maskFill.setFill()
        path.fill()
    }
}
