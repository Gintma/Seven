import AppKit
import ImageIO
import XCTest
@testable import Seven

@MainActor
final class ScreenshotSavingTests: XCTestCase {
    private let logicalSize = CGSize(width: 100, height: 65)

    func testRetinaSnapshotExportsFullPixelsAndPNGResolution() throws {
        let source = try solidImage(width: 200, height: 130, color: .red)
        let image = NSImage(cgImage: source, size: logicalSize)
        let bitmap = try XCTUnwrap(ScreenshotSaving.bitmap(image))
        XCTAssertEqual(bitmap.pixelsWide, 200)
        XCTAssertEqual(bitmap.pixelsHigh, 130)
        XCTAssertEqual(bitmap.size, logicalSize)
        try assertRetinaPNG(image)
    }

    func testMixedRepresentationsUseLargestPixelDimensionsForExport() throws {
        let low = NSBitmapImageRep(cgImage: try solidImage(width: 100, height: 65, color: .blue))
        let high = NSImage(cgImage: try solidImage(width: 200, height: 130, color: .red), size: logicalSize)
        let highRepresentation = try XCTUnwrap(high.representations.first)
        for representations in [[low, highRepresentation], [highRepresentation, low]] {
            let mixed = NSImage(size: logicalSize)
            representations.forEach(mixed.addRepresentation)
            let raster = try XCTUnwrap(ScreenshotSaving.cgImage(mixed))
            XCTAssertEqual(raster.width, 200)
            XCTAssertEqual(raster.height, 130)
            let bitmap = try XCTUnwrap(ScreenshotSaving.bitmap(mixed))
            XCTAssertEqual(bitmap.pixelsWide, 200)
            XCTAssertEqual(bitmap.pixelsHigh, 130)
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 25, y: 25)?.usingColorSpace(.deviceRGB)).redComponent, 0.9)
            try assertRetinaPNG(mixed)
        }
    }

    func testMixedRepresentationsUseBackingRasterSizeWhenRepReports1xPixels() throws {
        // Simulates NSCGImageSnapshotRep on a 1x display where pixelsWide reports logical 1x width while cgImage holds 2x pixels.
        final class ScaledSnapshotRep: NSImageRep {
            private let backing: CGImage
            init(backing: CGImage, reportedWidth: Int, reportedHeight: Int, logicalSize: CGSize) {
                self.backing = backing
                super.init()
                self.size = logicalSize
                self.pixelsWide = reportedWidth
                self.pixelsHigh = reportedHeight
            }
            required init?(coder: NSCoder) { nil }
            override func cgImage(
                forProposedRect proposedDestRect: UnsafeMutablePointer<NSRect>?,
                context: NSGraphicsContext?,
                hints: [NSImageRep.HintKey: Any]?
            ) -> CGImage? {
                backing
            }
        }

        let low = NSBitmapImageRep(cgImage: try solidImage(width: 100, height: 65, color: .blue))
        let high = ScaledSnapshotRep(
            backing: try solidImage(width: 200, height: 130, color: .red),
            reportedWidth: 100,
            reportedHeight: 65,
            logicalSize: logicalSize
        )
        for representations in [[low, high], [high, low]] {
            let mixed = NSImage(size: logicalSize)
            representations.forEach(mixed.addRepresentation)
            let raster = try XCTUnwrap(ScreenshotSaving.cgImage(mixed))
            XCTAssertEqual(raster.width, 200)
            XCTAssertEqual(raster.height, 130)
            let bitmap = try XCTUnwrap(ScreenshotSaving.bitmap(mixed))
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 25, y: 25)?.usingColorSpace(.deviceRGB)).redComponent, 0.9)
        }
    }

    func testPDFWithoutNativePixelDimensionsCanBeRasterizedAndExported() throws {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 20, height: 10)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.red.cgColor)
        context.fill(bounds)
        context.endPDFPage()
        context.closePDF()

        let image = try XCTUnwrap(NSImage(data: data as Data))
        XCTAssertFalse(image.representations.isEmpty)
        XCTAssertTrue(image.representations.allSatisfy { $0.pixelsWide == 0 && $0.pixelsHigh == 0 })
        let bitmap = try XCTUnwrap(ScreenshotSaving.bitmap(image))
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertEqual(bitmap.pixelsWide, bitmap.pixelsHigh * 2)
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent, 0.9)
        XCTAssertGreaterThan(color.alphaComponent, 0.99)
        XCTAssertNotNil(ScreenshotSaving.data(image, format: .png))
    }

    func testMosaicReducesDetailAndPreservesTransparentAndOpaqueRegions() throws {
        for opaque in [false, true] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            if opaque {
                context.setFillColor(NSColor.green.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
            }
            for x in stride(from: 0, to: 40, by: 4) {
                context.setFillColor((x.isMultiple(of: 8) ? NSColor.white : NSColor.black).cgColor)
                context.fill(CGRect(x: x, y: 0, width: 4, height: 40))
            }
            let source = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 80, height: 40))
            let mosaic = try XCTUnwrap(ScreenshotEditorEffects(base: source).image(level: 8, blurred: false))
            let bitmap = try XCTUnwrap(ScreenshotSaving.bitmap(mosaic))
            XCTAssertEqual(mosaic.size, source.size)
            XCTAssertEqual(bitmap.pixelsWide, 40)
            XCTAssertEqual(bitmap.pixelsHigh, 20)

            let stripes = try (2..<16).map { x in
                try XCTUnwrap(bitmap.colorAt(x: x, y: 10)?.usingColorSpace(.deviceRGB))
            }
            XCTAssertTrue(stripes.allSatisfy { $0.alphaComponent > 0.99 })
            let transitions = zip(stripes, stripes.dropFirst()).filter { abs($0.redComponent - $1.redComponent) > 0.1 }
            XCTAssertLessThanOrEqual(transitions.count, 2)

            let right = try XCTUnwrap(bitmap.colorAt(x: 32, y: 10)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(right.alphaComponent, opaque ? 1 : 0, accuracy: 0.01)
            if opaque { XCTAssertGreaterThan(right.greenComponent, 0.9) }
        }
    }

    private func solidImage(width: Int, height: Int, color: NSColor) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func assertRetinaPNG(_ image: NSImage) throws {
        let png = try XCTUnwrap(ScreenshotSaving.data(image, format: .png))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 200)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 130)
        XCTAssertEqual(properties[kCGImagePropertyDPIWidth] as? Int, 144)
        XCTAssertEqual(properties[kCGImagePropertyDPIHeight] as? Int, 144)
        let pngProperties = try XCTUnwrap(properties[kCGImagePropertyPNGDictionary] as? [CFString: Any])
        XCTAssertEqual(pngProperties[kCGImagePropertyPNGXPixelsPerMeter] as? Int, 5669)
        XCTAssertEqual(pngProperties[kCGImagePropertyPNGYPixelsPerMeter] as? Int, 5669)
    }
}
