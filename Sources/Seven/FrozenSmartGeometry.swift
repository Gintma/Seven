import Foundation

/// 在冻结图的物理像素网格上命中，AppKit 仍使用全局逻辑坐标。
struct FrozenSmartGeometry: Sendable {
    let screenFrame: CGRect
    let pixelSize: CGSize
    let primaryScreenTop: CGFloat
    private var scaleX: CGFloat { pixelSize.width / screenFrame.width }
    private var scaleY: CGFloat { pixelSize.height / screenFrame.height }

    /// 取实际鼠标所在像素的中心，避免把半开矩形的顶边误判到另一行。
    func point(_ global: CGPoint) -> CGPoint {
        let x = floor((global.x - screenFrame.minX) * scaleX)
        let y = floor((screenFrame.maxY - global.y) * scaleY)
        return CGPoint(x: screenFrame.minX + (x + 0.5) / scaleX,
                       y: screenFrame.maxY - (y + 0.5) / scaleY)
    }
    /// 与冻结截图裁剪一致，边界向外对齐到完整像素；Retina 保留半点边界。
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
    /// 已按同一窗口及滚动视口裁剪的兄弟控件，供本次截图复用。
    var siblings: [FrozenSmartRegion] = []
}
