import Foundation

/// Hit-tests on the frozen image's physical pixel grid while AppKit continues using global logical coordinates.
struct FrozenSmartGeometry: Sendable {
    let screenFrame: CGRect
    let pixelSize: CGSize
    let primaryScreenTop: CGFloat
    private var scaleX: CGFloat { pixelSize.width / screenFrame.width }
    private var scaleY: CGFloat { pixelSize.height / screenFrame.height }

    /// Samples the center of the pixel under the cursor to avoid assigning a half-open rect's top edge to an adjacent row.
    func point(_ global: CGPoint) -> CGPoint {
        let x = floor((global.x - screenFrame.minX) * scaleX)
        let y = floor((screenFrame.maxY - global.y) * scaleY)
        return CGPoint(x: screenFrame.minX + (x + 0.5) / scaleX,
                       y: screenFrame.maxY - (y + 0.5) / scaleY)
    }
    /// Aligns bounds outward to whole pixels to match frozen screenshot cropping; Retina preserves half-point boundaries.
    func rect(_ global: CGRect) -> CGRect {
        guard !global.isNull, !global.isEmpty, global.minX.isFinite, global.minY.isFinite,
              global.width.isFinite, global.height.isFinite else { return .null }
        let pixels = CGRect(x: (global.minX - screenFrame.minX) * scaleX,
            y: (screenFrame.maxY - global.maxY) * scaleY,
            width: global.width * scaleX, height: global.height * scaleY).integral
        return CGRect(x: screenFrame.minX + pixels.minX / scaleX,
            y: screenFrame.maxY - pixels.maxY / scaleY, width: pixels.width / scaleX, height: pixels.height / scaleY)
    }
}

struct FrozenSmartSelectionResult: Sendable {
    var ancestry: [FrozenSmartRegion] = []
    /// Sibling controls already clipped to the same window and scroll viewport for reuse within this capture session.
    var siblings: [FrozenSmartRegion] = []
}
