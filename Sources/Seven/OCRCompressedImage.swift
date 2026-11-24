import CoreGraphics
import Foundation

/// Keeps the original raster format and color profile. Only owned, conventional RGBA bitmaps are eligible.
struct OCRCompressedImage: Sendable {
    private static let minimumByteCount = 12 * 1_024 * 1_024
    private let bytes: Data
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private let colorSpace: CGColorSpace
    private let bitmapInfo: CGBitmapInfo
    private let shouldInterpolate: Bool
    private let renderingIntent: CGColorRenderingIntent

    init?(_ image: CGImage) {
        if #available(macOS 15, *), image.contentHeadroom > 1 { return nil }
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.decode == nil,
              let colorSpace = image.colorSpace, colorSpace.model == .rgb, !CGColorSpaceUsesExtendedRange(colorSpace),
              image.bytesPerRow >= image.width * 4 else { return nil }
        let (byteCount, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !overflow, byteCount >= Self.minimumByteCount,
              !Task.isCancelled,
              let raster = image.dataProvider?.data, CFDataGetLength(raster) == byteCount,
              let compressed = try? ((raster as Data) as NSData).compressed(using: .lzfse),
              compressed.length <= byteCount / 2 else { return nil }
        self.bytes = compressed as Data
        width = image.width
        height = image.height
        bytesPerRow = image.bytesPerRow
        self.colorSpace = colorSpace
        bitmapInfo = image.bitmapInfo
        shouldInterpolate = image.shouldInterpolate
        renderingIntent = image.renderingIntent
    }

    func makeImage() -> CGImage? {
        guard let raster = try? (bytes as NSData).decompressed(using: .lzfse),
              raster.length == bytesPerRow * height,
              let provider = CGDataProvider(data: (raster as Data) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: shouldInterpolate,
                       intent: renderingIntent)
    }
}
