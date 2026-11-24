import AppKit

enum ScreenshotClipboardPinError: LocalizedError {
    case empty, tooLarge
    var errorDescription: String? {
        self == .empty ? L10n.text("theClipboardHasNoUsableImageOr") : L10n.text("theClipboardContentsAreTooLargeTo")
    }
}

@MainActor enum ScreenshotClipboardPin {
    /// 只在用户触发时读取。图片优先，文字按本机字体排版；不发网络、不写磁盘或日志。
    static func image(from pasteboard: NSPasteboard) throws -> NSImage {
        do { return try ImageImport.clipboard(pasteboard, preservingLogicalSize: true) }
        catch ImageImportError.noImage { /* 只有没有图片/文件引用时才允许文字钉图。 */ }
        guard let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ScreenshotClipboardPinError.empty }
        return try textImage(text)
    }
    static func textImage(_ text: String, scale: CGFloat? = nil) throws -> NSImage {
        let palette = ThemeManager.shared.palette
        let storage = NSTextStorage(string: text, attributes: [.font: Design.Text.content.nsFont, .foregroundColor: palette.ink])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: Design.ScreenshotPin.textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(for: container)
        let layout = manager.usedRect(for: container).union(manager.boundingRect(forGlyphRange: glyphs, in: container))
        let inset = Design.ScreenshotPin.textInset
        let size = CGSize(width: ceil(layout.width) + inset*2, height: ceil(layout.height) + inset*2)
        // 测量与绘制使用同一次TextKit排版，不按测得的文字宽度重新换行，避免末行被截断。
        guard size.width * size.height * 4 <= CGFloat(ScreenshotScrollPolicy.maximumPixels) else { throw ScreenshotClipboardPinError.tooLarge }
        let scale = scale ?? NSScreen.main?.backingScaleFactor ?? 1
        let pixelWidth = Int(ceil(size.width * scale))
        let pixelHeight = Int(ceil(size.height * scale))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ScreenshotClipboardPinError.tooLarge
        }
        let graphics = context.cgContext
        graphics.translateBy(x: 0, y: CGFloat(pixelHeight))
        graphics.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics, flipped: true)
        palette.surfaceInset.setFill()
        CGRect(origin: .zero, size: size).fill()
        let origin = CGPoint(x: inset-layout.minX, y: inset-layout.minY)
        withExtendedLifetime(storage) {
            manager.drawBackground(forGlyphRange: glyphs, at: origin)
            manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        }
        graphics.flush()
        bitmap.size = size
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }
}
