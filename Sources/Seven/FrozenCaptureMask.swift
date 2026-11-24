import AppKit

/// 框选、区域编辑与窗口编辑共用的冻结画面蒙层；不参与图片导出。
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
    /// 滚动截图只绘制选区外蒙层，不冻结底图；鼠标穿透由所属窗口控制。
    static func drawOverlay(in bounds: CGRect, revealing rect: CGRect) {
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(rect: rect.intersection(bounds)))
        path.windingRule = .evenOdd
        Design.ScreenshotCapture.maskFill.setFill()
        path.fill()
    }
}
