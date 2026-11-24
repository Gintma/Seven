import AppKit

@MainActor enum ScreenshotAnnotationRendering {
    static func contrast(for color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return Design.ScreenshotEditor.handleFill }
        return rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722 > 0.6
            ? Design.ScreenshotEditor.highlightFill : Design.ScreenshotEditor.handleFill
    }
    static func drawMarker(_ stroke: ScreenshotEditorStroke) {
        guard stroke.marker != .none, let anchor = stroke.markerAnchor else { return }
        stroke.color.set()
        if !stroke.text.isEmpty || stroke.start != anchor {
            let line = NSBezierPath()
            line.move(to: anchor); line.line(to: stroke.textAttachment)
            line.lineWidth = Design.ScreenshotEditor.annotationLineWidth
            line.stroke()
        }
        let radius = stroke.marker == .dot ? stroke.markerSize * Design.ScreenshotEditor.annotationDotRatio : stroke.markerSize * Design.ScreenshotEditor.annotationNumberRatio
        NSBezierPath(ovalIn: CGRect(x: anchor.x - radius, y: anchor.y - radius, width: radius * 2, height: radius * 2)).fill()
        if stroke.marker == .number {
            let text = String(stroke.serial) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: Design.ScreenshotEditor.serialFont(stroke.markerSize * Design.ScreenshotEditor.annotationNumberFontRatio), .foregroundColor: contrast(for: stroke.color)]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2), withAttributes: attrs)
        }
    }
}
