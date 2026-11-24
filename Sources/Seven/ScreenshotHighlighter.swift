import AppKit
import Vision

/// 返回图片内归一化的文字行边界；仅在截图画笔中使用，不影响翻译 OCR。
protocol ScreenshotTextLineRecognizing {
    func lines(in image: CGImage) async throws -> [CGRect]
}

struct ScreenshotTextLineRecognizer: ScreenshotTextLineRecognizing {
    func lines(in image: CGImage) async throws -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: image).perform([request])
            try Task.checkCancellation()
            return (request.results ?? []).map(\.boundingBox)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: {
            request.cancel(); worker.cancel()
        }
    }
}

enum ScreenshotHighlighter {
    static func line(at point: CGPoint, in lines: [CGRect], size: CGSize) -> CGRect? {
        lines.map { CGRect(x: $0.minX * size.width, y: $0.minY * size.height,
                           width: $0.width * size.width, height: $0.height * size.height) }
            .filter { $0.insetBy(dx: -Design.ScreenshotEditor.highlighterTextPadding, dy: -Design.ScreenshotEditor.highlighterTextPadding).contains(point) }
            .min { $0.height < $1.height }
    }
    @MainActor static func cursor(height: CGFloat, palette: ThemePalette = .system) -> NSCursor {
        let width = Design.ScreenshotEditor.highlighterCursorWidth
        let height = max(height, Design.ScreenshotEditor.highlighterCursorMinimumHeight)
        let white = Design.ScreenshotEditor.highlighterCursorWhiteWidth
        let black = Design.ScreenshotEditor.highlighterCursorBlackWidth
        let radius = Design.ScreenshotEditor.highlighterRadius
        let image = NSImage(size: CGSize(width: width, height: height), flipped: false) { rect in
            let outer = NSBezierPath(roundedRect: rect.insetBy(dx: white / 2, dy: white / 2), xRadius: radius, yRadius: radius)
            palette.highlighterCursorOuter.setStroke()
            outer.lineWidth = white; outer.stroke()
            let inset = white + black / 2
            let inner = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: max(0, radius - inset + white / 2), yRadius: max(0, radius - inset + white / 2))
            palette.highlighterCursorInner.setStroke()
            inner.lineWidth = black; inner.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: width / 2, y: height / 2))
    }
}
