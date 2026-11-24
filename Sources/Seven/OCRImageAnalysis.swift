import AppKit
import VisionKit

/// 图片文字选择由系统在本机分析，不启用识图、链接检测或任何网络操作。
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
            // 直接传入限额位图，避免 NSImage 按屏幕倍率重新栅格化。
            return try await analyzer.analyze(image, orientation: .up, configuration: configuration)
        }
    }
}

enum OCRImageAnalysisInput {
    case original(NSImage)
    case raster(CGImage)

    // macOS 26 的 VisionKit 拒绝长边达到 8192 像素的图像。
    private static let maximumEdge: CGFloat = 8_191
    // 限制分析服务可能在取消后继续持有的 32 位像素缓冲。
    private static let maximumPixelCount: CGFloat = 8 * 1_024 * 1_024

    @MainActor static func prepare(_ image: NSImage) async throws -> Self? {
        try Task.checkCancellation()
        guard image.representations.contains(where: {
            scale(width: $0.pixelsWide, height: $0.pixelsHigh) < 1
        }) else { return .original(image) }
        guard let raster = autoreleasepool(invoking: {
            image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }) else { return nil }
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
