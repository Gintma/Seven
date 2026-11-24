import AppKit

/// 放大镜先将鼠标位置对齐到整数像素，再以此为中心计算 12pt 采样框。
enum FrozenMagnifierGeometry {
    static func pixel(point: CGPoint, scale: CGFloat, imageSize: CGSize) -> CGPoint {
        let ratio = CGFloat(Float(scale))
        return CGPoint(x: min(max(0, CGFloat(Int(point.x * ratio))), imageSize.width - 1),
                       y: min(max(0, imageSize.height - 1 - CGFloat(Int(point.y * ratio))), imageSize.height - 1))
    }

    static func sampleRect(point: CGPoint, screenSize: CGSize, scale: CGFloat) -> CGRect {
        let ratio = CGFloat(Float(scale))
        return CGRect(x: CGFloat(Float(Int(point.x * ratio))) - Design.ScreenshotMagnifier.sampleRadius * ratio,
                      y: screenSize.height * ratio - CGFloat(Int(point.y * ratio)) - Design.ScreenshotMagnifier.sampleRadius * ratio,
                      width: Design.ScreenshotMagnifier.sampleSide * ratio,
                      height: Design.ScreenshotMagnifier.sampleSide * ratio)
    }

    /// 放大镜固定在鼠标左上方，并限制在屏幕范围内。
    static func origin(mouse: CGPoint, screenSize: CGSize) -> CGPoint {
        let size = Design.ScreenshotMagnifier.size
        let x = CGFloat(Int(mouse.x)) - Design.ScreenshotMagnifier.sizeAndDistance
        let y = CGFloat(Int(mouse.y)) + Design.ScreenshotMagnifier.distance
        return CGPoint(x: min(max(0, x), max(0, screenSize.width - size)),
                       y: min(max(0, y), max(0, screenSize.height - size)))
    }

}

/// 120pt 的像素网格从未遮罩的冻结屏幕图采样。
final class FrozenMagnifierView: ThemedDrawingView {
    private var sample: CGImage?
    private(set) var sampledColor: NSColor?
    private(set) var hexColor: String?
    private(set) var coordinateText = ""
    private var valuesAreDark = true

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Design.ScreenshotMagnifier.size, height: Design.ScreenshotMagnifier.size))
        isHidden = true
        setAccessibilityLabel(L10n.text("pixelMagnifier"))
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(image: CGImage, point: CGPoint, screenSize: CGSize) {
        let scale = CGFloat(image.width) / screenSize.width
        let rect = FrozenMagnifierGeometry.sampleRect(point: point, screenSize: screenSize, scale: scale)
        sample = image.cropping(to: rect)
        coordinateText = FrozenMagnifierLabels.coordinate(point, screenHeight: screenSize.height)
        // 裁片在屏幕边缘会被截短；取色始终独立读取鼠标对应的原图像素。
        let pixel = FrozenMagnifierGeometry.pixel(point: point, scale: scale,
            imageSize: CGSize(width: image.width, height: image.height))
        sampledColor = image.cropping(to: CGRect(origin: pixel, size: CGSize(width: 1, height: 1)))
            .flatMap { NSBitmapImageRep(cgImage: $0).colorAt(x: 0, y: 0) }
        hexColor = sampledColor.map {
            FrozenMagnifierLabels.hex(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent)
        }
        if let sample {
            let bitmap = NSBitmapImageRep(cgImage: sample)
            valuesAreDark = Self.isBright(bitmap, rows: max(0, sample.height - 6)..<sample.height)
        }
        frame.origin = FrozenMagnifierGeometry.origin(mouse: point, screenSize: screenSize)
        isHidden = sample == nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let sample else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSGraphicsContext.current?.shouldAntialias = false
        NSImage(cgImage: sample, size: bounds.size).draw(in: bounds)
        Design.ScreenshotMagnifier.gridColor.setStroke()
        let grid = NSBezierPath()
        var position = Design.ScreenshotMagnifier.gridStep
        while position < Design.ScreenshotMagnifier.size {
            let line = position + Design.ScreenshotMagnifier.gridOffset
            grid.move(to: CGPoint(x: line, y: 0)); grid.line(to: CGPoint(x: line, y: bounds.height))
            grid.move(to: CGPoint(x: 0, y: line)); grid.line(to: CGPoint(x: bounds.width, y: line))
            position += Design.ScreenshotMagnifier.gridStep
        }
        grid.stroke()
        theme.captureMagnifierBorder.setStroke()
        let border = NSBezierPath(rect: CGRect(x: Design.ScreenshotMagnifier.outerInset, y: Design.ScreenshotMagnifier.outerInset, width: Design.ScreenshotMagnifier.outerSide, height: Design.ScreenshotMagnifier.outerSide))
        border.lineWidth = Design.ScreenshotMagnifier.outerLineWidth; border.stroke()
        let center = NSBezierPath(rect: CGRect(x: Design.ScreenshotMagnifier.centerOrigin, y: Design.ScreenshotMagnifier.centerOrigin, width: Design.ScreenshotMagnifier.centerBoxSide, height: Design.ScreenshotMagnifier.centerBoxSide))
        center.lineWidth = Design.ScreenshotMagnifier.centerLineWidth; center.stroke()
        theme.captureCrosshair.setStroke()
        let crosshair = NSBezierPath()
        let axis = Design.ScreenshotMagnifier.crosshairAxis
        let before = Design.ScreenshotMagnifier.crosshairGapStart
        let after = Design.ScreenshotMagnifier.crosshairGapEnd
        crosshair.move(to: CGPoint(x: 0, y: axis)); crosshair.line(to: CGPoint(x: before, y: axis))
        crosshair.move(to: CGPoint(x: after, y: axis)); crosshair.line(to: CGPoint(x: bounds.width, y: axis))
        crosshair.move(to: CGPoint(x: axis, y: 0)); crosshair.line(to: CGPoint(x: axis, y: before))
        crosshair.move(to: CGPoint(x: axis, y: after)); crosshair.line(to: CGPoint(x: axis, y: bounds.maxY))
        crosshair.lineWidth = Design.ScreenshotMagnifier.crosshairWidth
        crosshair.stroke()
        NSGraphicsContext.current?.shouldAntialias = true
        drawLabels()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func isBright(_ bitmap: NSBitmapImageRep, rows: Range<Int>) -> Bool {
        var total: Double = 0
        for row in rows {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: row) else { continue }
                total += Double(Float(color.redComponent) + Float(color.greenComponent) + Float(color.blueComponent))
            }
        }
        return Float(total / Double(rows.count * bitmap.pixelsWide) / 3) > 0.5
    }
    private func drawLabels() {
        guard let hexColor else { return }
        let coordinate = coordinateText as NSString
        let hex = hexColor as NSString
        let strings = [coordinate, hex]
        let font = Design.ScreenshotMagnifier.smallFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let locations = FrozenMagnifierLabels.origins(
            coordinateWidth: coordinate.size(withAttributes: attributes).width,
            hexWidth: hex.size(withAttributes: attributes).width
        )
        let dark = Design.ScreenshotMagnifier.labelDark
        let light = Design.ScreenshotMagnifier.labelLight
        for (index, pass) in locations.enumerated() {
            let isForeground = index == locations.count - 1
            let color = (isForeground == valuesAreDark) ? dark : light
            for (string, origin) in zip(strings, pass) {
                string.draw(at: origin, withAttributes: [.font: font, .foregroundColor: color])
            }
        }
    }
}

/// 格式化坐标与 HEX，并按文字宽度计算标签位置。
enum FrozenMagnifierLabels {
    static func coordinate(_ point: CGPoint, screenHeight: CGFloat) -> String {
        String(format: "%.f,%.f", Double(point.x), Double(screenHeight - point.y))
    }

    static func hex(red: CGFloat, green: CGFloat, blue: CGFloat) -> String {
        [red, green, blue].map { String(format: "%02X", Int($0 * 255 + 0.5)) }.joined()
    }

    static func origins(coordinateWidth: CGFloat, hexWidth: CGFloat) -> [[CGPoint]] {
        let coordinate = 30 - coordinateWidth * 0.5
        let hex = 90 - hexWidth * 0.5
        let offsets: [(CGFloat, CGFloat)] = [
            (0, 1), (0, -1), (-1, 0), (1, 0),
            (-0.7, 0.7), (0.7, 0.7), (-0.7, -0.7), (0.7, -0.7), (0, 0)
        ]
        return offsets.map { dx, dy in
            [
                CGPoint(x: coordinate + dx, y: 3 + dy),
                CGPoint(x: hex + dx, y: 3 + dy)
            ]
        }
    }
}
