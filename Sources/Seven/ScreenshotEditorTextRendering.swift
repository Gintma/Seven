import AppKit

/// Uses one shared set of text attributes across native editing, preview, and export rendering.
@MainActor enum ScreenshotEditorTextRendering {
    /// Draws annotations directly into the screen or export context to avoid blurry glyphs from rasterizing and scaling.
    static func drawBackdrop(_ stroke: ScreenshotEditorStroke) {
        guard let style=stroke.textBackdropStyle,let frame=stroke.textBackdropFrame else{return}
        let inset=style == .background ? 0:Design.AnnotationEditor.textBorderInset
        let path = NSBezierPath(roundedRect: frame, xRadius: max(0, Design.AnnotationEditor.radius-inset), yRadius: max(0, Design.AnnotationEditor.radius-inset))
        if style == .background { stroke.color.setFill(); path.fill() }
        else { stroke.color.setStroke(); path.lineWidth = Design.AnnotationEditor.borderWidth; path.stroke() }
    }
    static func attributes(for stroke: ScreenshotEditorStroke) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .left
        let foreground = stroke.textStyle == .background ? ScreenshotAnnotationRendering.contrast(for: stroke.color) : stroke.color
        let attributes: [NSAttributedString.Key: Any] = [.font: Design.ScreenshotEditor.font(size: stroke.width), .foregroundColor: foreground, .paragraphStyle: paragraph]
        return attributes
    }
    static func draw(_ stroke: ScreenshotEditorStroke) {
        drawBackdrop(stroke)
        guard !stroke.text.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let storage = NSTextStorage(string: stroke.text, attributes: attributes(for: stroke))
        storage.fixFontAttribute(in:NSRange(location:0,length:storage.length))
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: stroke.textBoxWidth ?? stroke.rect.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0; manager.addTextContainer(container); storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        NSGraphicsContext.saveGraphicsState()
        context.translateBy(x: stroke.textGlyphFrame.minX, y: stroke.textGlyphFrame.maxY)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: .zero)
        NSGraphicsContext.restoreGraphicsState()
    }
}
