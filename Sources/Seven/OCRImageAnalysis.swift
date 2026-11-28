import AppKit
import VisionKit

/// Image text selection is analyzed locally by the system, with visual lookup, link detection, and all network operations disabled.
@MainActor protocol OCRImageAnalyzing {
    func analyze(_ input: OCRImageAnalysisInput, language: String) async throws -> ImageAnalysis?
}

@MainActor struct SystemOCRImageAnalyzer: OCRImageAnalyzing {
    func analyze(_ input: OCRImageAnalysisInput, language: String) async throws -> ImageAnalysis? {
        guard ImageAnalyzer.isSupported else { return nil }
        var configuration = ImageAnalyzer.Configuration(.text)
        if language != LanguageCatalog.automatic { configuration.locales = [language] }
        let analyzer = ImageAnalyzer()
        switch input {
        case .original(let image):
            return try await analyzer.analyze(image, orientation: .up, configuration: configuration)
        case .raster(let image):
            // Pass the capped bitmap directly to avoid NSImage re-rasterizing at the display scale factor.
            return try await analyzer.analyze(image, orientation: .up, configuration: configuration)
        }
    }
}

enum OCRImageAnalysisInput {
    case original(NSImage)
    case raster(CGImage)

    // VisionKit on macOS 26 rejects images with a longest edge of 8192 pixels or more.
    private static let maximumEdge: CGFloat = 8_191
    // Cap the 32-bit pixel buffer that the analysis service may retain after cancellation.
    private static let maximumPixelCount: CGFloat = 8 * 1_024 * 1_024

    @MainActor static func prepare(_ image: NSImage) async throws -> Self? {
        try Task.checkCancellation()
        guard image.representations.contains(where: { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }) else {
            return .original(image)
        }
        // Inspect the backing raster directly so 1x displays do not under-report 2x snapshot dimensions.
        guard let raster = autoreleasepool(invoking: { ScreenshotSaving.cgImage(image) }) else {
            return .original(image)
        }
        guard scale(width: raster.width, height: raster.height) < 1 else {
            return .original(image)
        }
        let resizing = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return autoreleasepool { resizedRaster(raster) }
        }
        let resized = try await withTaskCancellationHandler { try await resizing.value } onCancel: { resizing.cancel() }
        try Task.checkCancellation()
        guard let resized else { return nil }
        return .raster(resized)
    }

    private static func scale(width: Int, height: Int) -> CGFloat {
        guard width > 0, height > 0 else { return 1 }
        let pixelCount = CGFloat(width) * CGFloat(height)
        return min(1, maximumEdge / CGFloat(max(width, height)), sqrt(maximumPixelCount / pixelCount))
    }

    private static func resizedRaster(_ source: CGImage) -> CGImage? {
        let scale = scale(width: source.width, height: source.height)
        let width = max(1, Int(CGFloat(source.width) * scale))
        let height = max(1, Int(CGFloat(source.height) * scale))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: .init(alpha: .premultipliedLast)) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
