import AppKit

extension NSImage {
    /// Width of the image's actual inked bounds (excluding SF Symbol side bearings), used to lay out icons by visible width.
    var inkWidth: CGFloat {
        let scale: CGFloat = 2
        let pixelsWide = Int(ceil(size.width * scale)), pixelsHigh = Int(ceil(size.height * scale))
        guard pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return size.width }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(in: NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        var minX = pixelsWide, maxX = -1
        for x in 0..<pixelsWide {
            for y in 0..<pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                break
            }
        }
        return maxX >= minX ? CGFloat(maxX - minX + 1) / scale : size.width
    }
}
