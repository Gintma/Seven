import AppKit

enum ScreenshotAspectRatio: String, CaseIterable {
    case free, square = "1:1", portrait = "3:4", landscape = "4:3", tall = "9:16", wide = "16:9", desktop = "16:10"
    var title: String { self == .free ? L10n.text("free") : rawValue }
    var value: CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .portrait: return 3 / 4
        case .landscape: return 4 / 3
        case .tall: return 9 / 16
        case .wide: return 16 / 9
        case .desktop: return 16 / 10
        }
    }
}

/// 数值以输出像素为准；选区几何仍使用当前屏幕的逻辑坐标。
enum ScreenshotSelectionSizing {
    /// 框选预览与编辑器共用像素圆角换算；小选区不超过短边的一半。
    static func cornerRadii(_ radius: CGFloat, logicalSize: CGSize, pixelSize: CGSize) -> CGSize {
        guard radius > 0, pixelSize.width > 0, pixelSize.height > 0 else { return .zero }
        let clamped = min(radius, (min(pixelSize.width, pixelSize.height) / 2).rounded(.down))
        return CGSize(width: clamped * logicalSize.width / pixelSize.width,
                      height: clamped * logicalSize.height / pixelSize.height)
    }
    static func pixelSize(_ selection: CGRect, context: FrozenSelectionContext) -> CGSize {
        ScreenshotGeometry.displayRect(for: selection, screenSize: context.screenFrame.size,
            displaySpaceSize: CGSize(width: context.image.width, height: context.image.height)).size
    }
    static func resized(_ selection: CGRect, width: Int? = nil, height: Int? = nil,
                        ratio: ScreenshotAspectRatio, context: FrozenSelectionContext) -> CGRect {
        let pixels = ScreenshotGeometry.displayRect(for: selection, screenSize: context.screenFrame.size,
            displaySpaceSize: CGSize(width: context.image.width, height: context.image.height))
        var w = max(1, CGFloat(width ?? Int(pixels.width))), h = max(1, CGFloat(height ?? Int(pixels.height)))
        let maxW = CGFloat(context.image.width), maxH = CGFloat(context.image.height)
        if let ratio = ratio.value {
            if height != nil, width == nil { w = h * ratio } else { h = w / ratio }
            let scale = min(1, min(maxW / w, maxH / h))
            w = max(1, (w * scale).rounded()); h = max(1, (h * scale).rounded())
        } else { w = min(w, maxW); h = min(h, maxH) }
        let x = min(pixels.minX, maxW - w), y = min(pixels.minY, maxH - h)
        let scaleX = maxW / context.screenFrame.width, scaleY = maxH / context.screenFrame.height
        return CGRect(x: x / scaleX, y: (maxH - y - h) / scaleY, width: w / scaleX, height: h / scaleY)
    }
    static func dragged(_ original: CGRect, handle: FrozenSelectionHandle, to point: CGPoint,
                        ratio: ScreenshotAspectRatio, context: FrozenSelectionContext) -> CGRect {
        guard let pixelRatio = ratio.value else {
            return FrozenSelectionGeometry.resized(original, handle: handle, to: point, within: context.screenFrame.size)
        }
        let scaleX = CGFloat(context.image.width) / context.screenFrame.width
        let scaleY = CGFloat(context.image.height) / context.screenFrame.height
        let r = pixelRatio * scaleY / scaleX
        let bounds = CGRect(origin: .zero, size: context.screenFrame.size)
        if handle == .left || handle == .right {
            let x = handle == .right ? original.minX : original.maxX
            let forward = point.x >= x
            let availableW = forward ? bounds.maxX - x : x
            let availableH = 2 * min(original.midY, bounds.maxY - original.midY)
            let w = min(abs(point.x - x), min(availableW, availableH * r))
            return CGRect(x: forward ? x : x - w, y: original.midY - w / r / 2, width: w, height: w / r)
        }
        if handle == .top || handle == .bottom {
            let y = handle == .top ? original.minY : original.maxY
            let forward = point.y >= y
            let availableH = forward ? bounds.maxY - y : y
            let availableW = 2 * min(original.midX, bounds.maxX - original.midX)
            let h = min(abs(point.y - y), min(availableH, availableW / r))
            return CGRect(x: original.midX - h * r / 2, y: forward ? y : y - h, width: h * r, height: h)
        }
        let anchor: CGPoint
        switch handle {
        case .topRight: anchor = CGPoint(x: original.minX, y: original.minY)
        case .topLeft: anchor = CGPoint(x: original.maxX, y: original.minY)
        case .bottomRight: anchor = CGPoint(x: original.minX, y: original.maxY)
        default: anchor = CGPoint(x: original.maxX, y: original.maxY)
        }
        let right = point.x >= anchor.x, up = point.y >= anchor.y
        let availableW = right ? bounds.maxX - anchor.x : anchor.x
        let availableH = up ? bounds.maxY - anchor.y : anchor.y
        let w = min(max(abs(point.x - anchor.x), abs(point.y - anchor.y) * r), min(availableW, availableH * r))
        return CGRect(x: right ? anchor.x : anchor.x - w, y: up ? anchor.y : anchor.y - w / r, width: w, height: w / r)
    }
}
