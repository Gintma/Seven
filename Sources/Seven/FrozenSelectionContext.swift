import AppKit
import CoreGraphics

/// Original frozen screen image and selection for a standard screenshot. Retained during annotation so moving or resizing the selection does not recapture.
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

/// Resize handles at the four corners and four edges of the selection.
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
    /// Translates the selection by the mouse delta, truncates the origin to integers clamped to screen bounds, and preserves width and height.
    /// Callers then update the drag anchor via movingAnchor(for:).
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

    /// Every drag is computed relative to the rect at mouse-down, including when dragging past the opposite edge.
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
        // Round and clamp both endpoints to screen bounds before computing origin and size.
        let x0 = min(max(Int(begin.x), 0), Int(size.width))
        let x1 = min(max(Int(end.x), 0), Int(size.width))
        let y0 = min(max(Int(begin.y), 0), Int(size.height))
        let y1 = min(max(Int(end.y), 0), Int(size.height))
        return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
    }
}
