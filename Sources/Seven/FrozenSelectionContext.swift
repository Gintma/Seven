import AppKit
import CoreGraphics

/// 普通截图的原始冻结屏幕和选区。标注阶段仍保留原图，移动/缩放选区不会重新截图。
struct FrozenSelectionContext {
    let screenFrame: CGRect
    let localSelection: CGRect
    let image: CGImage
    var isWindowComposition = false
    var backgroundImage: CGImage? = nil

    func croppedImage(in localRect: CGRect) -> NSImage? {
        FrozenScreenshotFrame(screenFrame: screenFrame, image: image).croppedImage(in: localRect)
    }
}

/// 选区四角与四边的缩放控制点。
enum FrozenSelectionHandle: Int, CaseIterable {
    case bottomLeft = 1, bottom, bottomRight, right, topRight, top, topLeft, left

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}

enum FrozenSelectionGeometry {
    /// 按鼠标增量平移选区，将原点截为整数并限制在屏幕内，保留原宽高。
    /// 调用方随后用 movingAnchor(for:) 更新拖动锚点。
    static func moved(_ rect: CGRect, from previous: CGPoint, to point: CGPoint, within size: CGSize) -> CGRect {
        var x = max(0, Int(point.x + rect.minX - previous.x))
        var y = max(0, Int(point.y + rect.minY - previous.y))
        if CGFloat(x) + rect.width > size.width { x = Int(size.width - rect.width) }
        if CGFloat(y) + rect.height > size.height { y = Int(size.height - rect.height) }
        return CGRect(x: CGFloat(x), y: CGFloat(y), width: rect.width, height: rect.height)
    }

    static func movingAnchor(for point: CGPoint) -> CGPoint {
        CGPoint(x: Int(point.x), y: Int(point.y))
    }

    /// 每次拖动都以按下鼠标时的矩形为基准，拖过对边时也使用同一基准。
    static func resized(_ original: CGRect, handle: FrozenSelectionHandle, to point: CGPoint, within size: CGSize) -> CGRect {
        var begin = original.origin
        var end = CGPoint(x: original.maxX, y: original.maxY)
        switch handle {
        case .bottomLeft: begin = point
        case .bottom: begin.y = point.y
        case .bottomRight: end.x = point.x; begin.y = point.y
        case .right: end.x = point.x
        case .topRight: end = point
        case .top: end.y = point.y
        case .topLeft: begin.x = point.x; end.y = point.y
        case .left: begin.x = point.x
        }
        // 先将两个端点取整并限制在屏幕内，再计算位置和尺寸。
        let x0 = min(max(Int(begin.x), 0), Int(size.width))
        let x1 = min(max(Int(end.x), 0), Int(size.width))
        let y0 = min(max(Int(begin.y), 0), Int(size.height))
        let y1 = min(max(Int(end.y), 0), Int(size.height))
        return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
    }
}
