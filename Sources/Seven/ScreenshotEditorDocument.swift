import AppKit
import CoreImage

/// 截图标注的工具编号。序号与文字共用工具栏入口。
enum ScreenshotEditorTool: Int, CaseIterable {
    case rectangle, ellipse, line, arrow, pencil, mosaic, text
    // 工具偏好以 rawValue 为持久化键，保留聚焦原来的编号。
    case highlight = 8

    static var toolbarCases: [Self] { allCases }

    var title: String {
        switch self {
        case .rectangle: return L10n.text("rectangle")
        case .ellipse: return L10n.text("ellipse")
        case .line: return L10n.text("straightLine")
        case .arrow: return L10n.text("arrow")
        case .pencil: return L10n.text("pen")
        case .mosaic: return L10n.text("pixelate")
        case .text: return L10n.text("textAnnotation")
        case .highlight: return L10n.text("spotlight")
        }
    }
    /// 各标注工具的默认尺寸。
    var defaultSize: CGFloat {
        switch self {
        case .rectangle, .ellipse, .mosaic, .highlight: return 3
        case .line, .pencil: return 16
        case .arrow: return 10
        case .text: return 18
        }
    }
    /// 尺寸控件按工具限制整数取值范围。
    var sizeRange: ClosedRange<Int> {
        switch self {
        case .text: return 10...100
        case .mosaic: return 1...10
        default: return 1...40
        }
    }
    var symbol: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .pencil: return "pencil.tip"
        case .mosaic: return Design.Icon.screenshotMosaic
        case .text: return "text.bubble"
        case .highlight: return Design.Icon.screenshotFocus
        }
    }
}

/// 文字标注的三种样式。
enum ScreenshotEditorTextStyle: Int, CaseIterable {
    case plain, background, outline
    static let toolbarCases: [Self] = [.background, .outline, .plain]
    var title: String { [L10n.text("plainText"), L10n.text("backgroundColor"), L10n.text("border")][rawValue] }
}

enum ScreenshotShapeMode: Int, CaseIterable {
    case outline, fill, solid
    var title: String { [L10n.text("outline"), L10n.text("fill"), L10n.text("solidFill")][rawValue] }
}

enum ScreenshotArrowStyle: Int, CaseIterable {
    // 保留已保存参数的编号，移除原来的实心头细杆样式（0）。
    case openHead = 1, solid = 2
    var title: String { self == .openHead ? L10n.text("openArrowhead") : L10n.text("thickFilledArrow") }
    var symbol: String { self == .openHead ? "arrow.up.right" : "arrowshape.up.fill" }
}

enum ScreenshotPencilMode: Int, CaseIterable {
    case freehand, highlighter
    static let toolbarCases: [Self] = [.highlighter, .freehand]
    var title: String { self == .highlighter ? L10n.text("straightHighlighter") : L10n.text("freehandPen") }
    var symbol: String { self == .highlighter ? "text.line.magnify" : "scribble" }
}

enum ScreenshotAnnotationMarker: Int, CaseIterable {
    case none, dot, number
    var title: String { [L10n.text("plainText"), L10n.text("dot"), L10n.text("number")][rawValue] }
    var symbol: String { ["nosign", "circle.fill", "1.circle.fill"][rawValue] }
}

struct ScreenshotEditorStroke: Equatable {
    let id: UUID
    var tool: ScreenshotEditorTool
    var isDeleted=false
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: NSColor
    var width: CGFloat
    var opacity: CGFloat
    var text = ""
    var textBoxWidth: CGFloat?
    var textWidthIsManual = false
    var textMaximumWidth = Design.AnnotationEditor.maximumAutoWidth
    var textTopY: CGFloat?
    var marker: ScreenshotAnnotationMarker = .none
    var markerAnchor: CGPoint?
    var markerSize = Design.ScreenshotEditor.textSize
    var isEditingPreview = false
    var isPlacementPreview = false
    var textLayoutBounds: CGRect?
    var focusIsEllipse = false
    var serial = 0
    var filled = false
    var fillHasBorder = false
    var cornerRadius = Design.ScreenshotEditor.defaultCornerRadius
    var dashed = false
    var shapeMode: ScreenshotShapeMode {
        get { filled ? (fillHasBorder ? .fill : .solid) : .outline }
        set { filled = newValue != .outline; fillHasBorder = newValue == .fill }
    }
    var rounded = false
    var blurred = false
    var curved = false
    var control1: CGPoint?
    var control2: CGPoint?
    var arrowStyle: ScreenshotArrowStyle = .solid
    var pencilMode: ScreenshotPencilMode = .freehand
    var textStyle: ScreenshotEditorTextStyle = .background
    mutating func setCurved(_ value: Bool) {
        curved = value
        if value, control1 == nil || control2 == nil { resetCurveControls() }
    }
    mutating func resetCurveControls() {
        let dx = end.x - start.x, dy = end.y - start.y
        control1 = CGPoint(x: start.x + dx / 3 - dy / 4, y: start.y + dy / 3 + dx / 4)
        control2 = CGPoint(x: start.x + dx * 2 / 3 - dy / 4, y: start.y + dy * 2 / 3 + dx / 4)
    }
    var rect: CGRect { CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x-start.x), height: abs(end.y-start.y)) }
    var textEditorFrame: CGRect { rect.insetBy(dx: -Design.AnnotationEditor.inset, dy: -Design.AnnotationEditor.inset) }
    var textDecorationFrame: CGRect { textEditorFrame.insetBy(dx: Design.AnnotationEditor.borderWidth, dy: Design.AnnotationEditor.borderWidth) }
    var textGlyphFrame: CGRect {
        let height = ScreenshotEditorGeometry.textSize(text, font: Design.ScreenshotEditor.font(size: width), wrappingWidth: textBoxWidth).height
        return CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    }
    func hitsTextBorder(_ point: CGPoint) -> Bool {
        let frame = textDecorationFrame
        let tolerance = Design.ScreenshotEditor.handleSize / 2
        return frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point) && !frame.insetBy(dx: tolerance, dy: tolerance).contains(point)
    }
    func hitsMarker(_ point: CGPoint) -> Bool {
        guard marker != .none, let anchor = markerAnchor else { return false }
        let radius = markerSize * (marker == .dot ? Design.ScreenshotEditor.annotationDotRatio : Design.ScreenshotEditor.annotationNumberRatio)
        return hypot(point.x - anchor.x, point.y - anchor.y) <= max(radius, Design.ScreenshotEditor.handleSize / 2)
    }
    var textBackdropStyle:ScreenshotEditorTextStyle? {
        let style=isPlacementPreview && textStyle == .plain ? ScreenshotEditorTextStyle.background:textStyle
        return style != .plain || (text.isEmpty && !isEditingPreview) ? style : nil
    }
    var textBackdropFrame:CGRect? {
        guard let style=textBackdropStyle else{return nil}
        let inset=style == .background ? 0:Design.AnnotationEditor.textBorderInset
        return textDecorationFrame.insetBy(dx:inset,dy:inset)
    }
    var textAttachment: CGPoint {
        let frame = textBackdropFrame ?? textDecorationFrame
        return CGPoint(x: (markerAnchor?.x ?? frame.minX) < frame.midX ? frame.minX : frame.maxX, y: frame.midY)
    }
    mutating func layoutText(_ value: String) {
        text = value
        let font = Design.ScreenshotEditor.font(size: width)
        var boxWidth: CGFloat
        if textWidthIsManual, let textBoxWidth {
            boxWidth = textBoxWidth
        } else {
            let natural = ScreenshotEditorGeometry.textSize(value, font: font)
            let emptyWidth = (max(Design.AnnotationEditor.minimumHeight, natural.height) + Design.AnnotationEditor.inset*2) * Design.AnnotationEditor.emptyAspectRatio - Design.AnnotationEditor.inset*2
            boxWidth = min(max(Design.AnnotationEditor.minimumWidth, value.isEmpty ? emptyWidth : ceil(natural.width) + Design.AnnotationEditor.textMeasurementPadding), max(Design.AnnotationEditor.minimumWidth, textMaximumWidth))
        }
        if !value.isEmpty {
            let widest = value.filter { !$0.isNewline }.map { ScreenshotEditorGeometry.textSize(String($0), font: font).width }.max() ?? 0
            boxWidth = max(boxWidth, widest + Design.AnnotationEditor.textMeasurementPadding)
        }
        textBoxWidth = boxWidth
        let size = ScreenshotEditorGeometry.textSize(value, font: font, wrappingWidth: boxWidth)
        let top = textTopY ?? (start.y + max(Design.AnnotationEditor.minimumHeight, size.height))
        textTopY = top
        start.y = top - max(Design.AnnotationEditor.minimumHeight, ceil(size.height))
        end = CGPoint(x: start.x + boxWidth, y: top)
        if !textWidthIsManual, let bounds = textLayoutBounds {
            let frame = textEditorFrame
            let dx = max(bounds.minX - frame.minX, min(0, bounds.maxX - frame.maxX))
            let dy = max(bounds.minY - frame.minY, min(0, bounds.maxY - frame.maxY))
            if frame.width <= bounds.width, frame.height <= bounds.height {
                translateText(to: CGPoint(x: start.x + dx, y: start.y + dy))
            }
        }
    }
    mutating func translateText(to point: CGPoint) {
        let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
        start = point; end.x += delta.x; end.y += delta.y
        if let top = textTopY { textTopY = top + delta.y }
    }
    mutating func translate(_ delta: CGPoint) {
        if let top = textTopY { textTopY = top + delta.y }
        if let p = markerAnchor { markerAnchor = CGPoint(x: p.x + delta.x, y: p.y + delta.y) }
        start.x += delta.x; start.y += delta.y; end.x += delta.x; end.y += delta.y
        points = points.map { CGPoint(x: $0.x+delta.x, y: $0.y+delta.y) }
        if let p = control1 { control1 = CGPoint(x:p.x+delta.x,y:p.y+delta.y) }
        if let p = control2 { control2 = CGPoint(x:p.x+delta.x,y:p.y+delta.y) }
    }
}

/// 同身份版本维护编辑历史；图层按首次创建顺序，预览和编辑不置顶。undo 排除历史尾部，新建截断 redo。
struct ScreenshotEditorDocument {
    private(set) var history: [ScreenshotEditorStroke] = []
    private(set) var undone = 0
    var preview: ScreenshotEditorStroke?
    private(set) var isGrouping = false
    private var pending: ScreenshotEditorStroke?
    var visible: [ScreenshotEditorStroke] {
        var order: [UUID] = []
        var latest: [UUID: ScreenshotEditorStroke] = [:]
        for stroke in history.prefix(history.count - undone) {
            if latest[stroke.id] == nil { order.append(stroke.id) }
            latest[stroke.id] = stroke
        }
        if let preview {
            if latest[preview.id] == nil { order.append(preview.id) }
            latest[preview.id] = preview
        }
        return order.compactMap { latest[$0] }.filter{!$0.isDeleted}
    }
    mutating func beginOperation() {
        guard !isGrouping else { return }
        isGrouping = true; pending = nil
    }
    mutating func endOperation() {
        guard isGrouping else { return }
        let final = pending
        isGrouping = false; pending = nil
        if let final { commit(final) }
    }
    mutating func commit(_ stroke: ScreenshotEditorStroke) {
        if isGrouping { pending = stroke; preview = stroke; return }
        preview = nil
        // 不记录改回原值、只选中或打开再关闭的空操作，也不因此丢弃重做。
        if history.prefix(history.count - undone).last(where: { $0.id == stroke.id }) == stroke { return }
        history.removeLast(undone); undone = 0; history.append(stroke)
    }
    mutating func delete(_ id:UUID) {
        guard var stroke=visible.first(where:{$0.id==id}) else{return}
        stroke.isDeleted=true;commit(stroke)
    }
    mutating func rebase(by delta: CGPoint) {
        for index in history.indices { history[index].translate(delta) }
        preview?.translate(delta)
        pending?.translate(delta)
    }
    mutating func undo() { endOperation(); preview = nil; undone = min(history.count,undone+1) }
    mutating func redo() { endOperation(); preview = nil; undone = max(0,undone-1) }
    private var hasPendingChange: Bool {
        guard let pending else { return false }
        return history.prefix(history.count - undone).last(where: { $0.id == pending.id }) != pending
    }
    var canUndo: Bool { undone < history.count || hasPendingChange }
    var canRedo: Bool { undone > 0 && !hasPendingChange }
}

enum ScreenshotEditorGeometry {
    /// 将实心直箭头的七点轮廓缩放并旋转到起点和终点之间。
    static func arrowVertices(start: CGPoint, end: CGPoint, width: CGFloat) -> [CGPoint] {
        let length = hypot(end.x-start.x,end.y-start.y)
        let scale = length == 0 ? 1/CGFloat(30) : length/30
        let q = (3*width+2)/scale
        let local: [CGPoint] = [.init(x:0,y:0.05),.init(x:30-q,y:0.4*q),.init(x:30-1.1*q,y:0.8*q),.init(x:30,y:0),.init(x:30-1.1*q,y:-0.8*q),.init(x:30-q,y:-0.4*q),.init(x:0,y:-0.05)]
        let angle = atan2(end.y-start.y,end.x-start.x)
        return local.map { point in
            CGPoint(x:start.x + scale*(point.x*cos(angle)-point.y*sin(angle)), y:start.y + scale*(point.x*sin(angle)+point.y*cos(angle)))
        }
    }
    /// 曲线箭头沿末端切线延伸 `2 * (width + 3)`。
    static func curveHead(end: CGPoint, control2: CGPoint, width: CGFloat) -> [CGPoint] {
        let dx = end.x-control2.x, dy = end.y-control2.y, length = hypot(dx,dy), a = width+3
        guard length != 0 else { return [] }
        let nx = -dy/length, ny = dx/length
        return [.init(x:end.x+a*nx,y:end.y+a*ny),.init(x:end.x-a*nx,y:end.y-a*ny),.init(x:end.x+2*a*dx/length,y:end.y+2*a*dy/length)]
    }
    /// 预生成表后十项半径为1.5*k-1.5，k=1...10；前十项像素块level为1...10。
    static func filterRadius(level:Int)->CGFloat {CGFloat(level)*1.5-1.5}
    static func path(_ stroke: ScreenshotEditorStroke) -> NSBezierPath {
        let path = NSBezierPath()
        switch stroke.tool {
        case .rectangle: return stroke.rounded ? NSBezierPath(roundedRect:stroke.rect,xRadius:stroke.cornerRadius,yRadius:stroke.cornerRadius) : NSBezierPath(rect:stroke.rect)
        case .ellipse: return NSBezierPath(ovalIn:stroke.rect)
        case .arrow where !stroke.curved && stroke.arrowStyle == .solid:
            let vertices = arrowVertices(start:stroke.start,end:stroke.end,width:stroke.width)
            if let first = vertices.first { path.move(to:first); vertices.dropFirst().forEach(path.line); path.close() }
        case .arrow where stroke.curved:
            path.move(to:stroke.start)
            path.curve(to:stroke.end, controlPoint1:stroke.control1 ?? stroke.start, controlPoint2:stroke.control2 ?? stroke.end)
        case .pencil where stroke.pencilMode == .highlighter:
            let rect = CGRect(x: min(stroke.start.x, stroke.end.x), y: stroke.start.y - stroke.width / 2,
                              width: abs(stroke.end.x - stroke.start.x), height: stroke.width)
            return NSBezierPath(roundedRect: rect, xRadius: Design.ScreenshotEditor.highlighterRadius, yRadius: Design.ScreenshotEditor.highlighterRadius)
        case .pencil:
            path.move(to:stroke.start); stroke.points.forEach(path.line)
        case .arrow: path.move(to: stroke.start); path.line(to: stroke.end)
        default: path.move(to:stroke.start); path.line(to:stroke.end)
        }
        return path
    }
    static func arrowHead(_ stroke: ScreenshotEditorStroke) -> NSBezierPath {
        let direction = stroke.curved ? stroke.control2 ?? stroke.start : stroke.start
        let angle = atan2(stroke.end.y - direction.y, stroke.end.x - direction.x)
        let length = min(hypot(stroke.end.x - stroke.start.x, stroke.end.y - stroke.start.y), stroke.width * 3)
        let halfWidth = length / 2
        let center = CGPoint(x: stroke.end.x - cos(angle) * length, y: stroke.end.y - sin(angle) * length)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: center.x - sin(angle) * halfWidth, y: center.y + cos(angle) * halfWidth))
        path.line(to: stroke.end)
        path.line(to: CGPoint(x: center.x + sin(angle) * halfWidth, y: center.y - cos(angle) * halfWidth))
        return path
    }
    /// 给已定位的文本框添加标识时，优先左右，其次上下，整个标识留在选区内。
    static func markerAnchor(frame: CGRect, bounds: CGRect, radius: CGFloat) -> CGPoint? {
        let safe = bounds.insetBy(dx: radius, dy: radius)
        guard !safe.isEmpty else { return nil }
        let gap = radius + Design.ScreenshotEditor.annotationMarkerGap
        let x = min(max(frame.midX, safe.minX), safe.maxX)
        let y = min(max(frame.midY, safe.minY), safe.maxY)
        return [CGPoint(x: frame.minX - gap, y: y), CGPoint(x: frame.maxX + gap, y: y),
                CGPoint(x: x, y: frame.maxY + gap), CGPoint(x: x, y: frame.minY - gap)].first { safe.contains($0) }
    }
    /// 使用 TextKit 测量行布局和字形边界，容器行片段不留内边距。
    static func textSize(_ text: String, font: NSFont, wrappingWidth: CGFloat? = nil) -> NSSize {
        let storage = NSTextStorage(string:text.isEmpty ? " " : text,attributes:[.font:font])
        storage.fixFontAttribute(in:NSRange(location:0,length:storage.length))
        let manager = NSLayoutManager(), container = NSTextContainer(containerSize:NSSize(width:wrappingWidth ?? CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0; manager.addTextContainer(container); storage.addLayoutManager(manager)
        manager.ensureLayout(for:container)
        let range = manager.glyphRange(for: container)
        let used = manager.usedRect(for: container)
        let ink = manager.boundingRect(forGlyphRange: range, in: container)
        return CGSize(width: ceil(max(used.maxX, ink.maxX)), height: ceil(max(used.maxY, ink.maxY)))
    }
    /// 计算三次 Bézier 曲线在参数 `t` 处的坐标。
    static func curvePoint(start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint, t: CGFloat) -> CGPoint {
        let u = 1 - t, tt = t * t, uu = u * u
        let a = u * uu, b = 3 * uu * t, c = 3 * u * tt, d = tt * t
        return CGPoint(x: ((start.x * a + control1.x * b) + control2.x * c) + end.x * d,
                       y: ((start.y * a + control1.y * b) + control2.y * c) + end.y * d)
    }
    /// 用线段与指针命中方框的四条边判断是否相交。
    static func segmentCrossesPointerBox(_ a: CGPoint, _ b: CGPoint, center: CGPoint, radius: CGFloat) -> Bool {
        let radius = CGFloat(Float(radius))
        let x1 = center.x - radius, x2 = center.x + radius, y1 = center.y - radius, y2 = center.y + radius
        let dx = b.x - a.x, dy = b.y - a.y
        for y in [y2, y1] {
            let x = a.x + dx * (y - a.y) / dy
            if x >= x1 && x <= x2 && y >= min(a.y, b.y) && y <= max(a.y, b.y) { return true }
        }
        for x in [x1, x2] {
            let y = a.y + dy * (x - a.x) / dx
            if y >= y1 && y <= y2 && x >= min(a.x, b.x) && x <= max(a.x, b.x) { return true }
        }
        return false
    }
    /// 根据三条有向边的叉积判断点是否位于三角形内，边界计入命中。
    static func triangleContains(_ point: CGPoint, _ vertices: [CGPoint]) -> Bool {
        guard vertices.count == 3 else { return false }
        let a = vertices[0], b = vertices[1], c = vertices[2]
        let values = [(point.x - c.x) * (a.y - c.y) - (a.x - c.x) * (point.y - c.y),
                      (point.x - a.x) * (b.y - a.y) - (point.y - a.y) * (b.x - a.x),
                      (point.x - b.x) * (c.y - b.y) - (point.y - b.y) * (c.x - b.x)]
        return !(values.contains { $0 < 0 } && values.contains { $0 > 0 })
    }
    static func hit(_ point: CGPoint, stroke: ScreenshotEditorStroke) -> Bool {
        let tolerance = CGFloat(max(5, (Int(stroke.width) + 1) / 2))
        switch stroke.tool {
        case .arrow where stroke.curved:
            let radius = CGFloat(max(3, Int(stroke.width)) / 2)
            var previous = stroke.start
            for index in 0..<100 {
                let sample = curvePoint(start: stroke.start, control1: stroke.control1 ?? stroke.start,
                                        control2: stroke.control2 ?? stroke.end, end: stroke.end, t: CGFloat(index) / 100)
                if segmentCrossesPointerBox(previous, sample, center: point, radius: radius) { return true }
                previous = sample
            }
            return triangleContains(point, curveHead(end: stroke.end, control2: stroke.control2 ?? stroke.start, width: CGFloat(max(3, Int(stroke.width)))))
        case .line:
            return segmentCrossesPointerBox(stroke.start, stroke.end, center: point, radius: CGFloat(max(3, Int(stroke.width) / 2)))
        case .pencil where stroke.pencilMode == .highlighter:
            return path(stroke).contains(point)
        case .arrow where stroke.arrowStyle != .solid:
            return segmentCrossesPointerBox(stroke.start, stroke.end, center: point, radius: max(3, stroke.width / 2)) || arrowHead(stroke).contains(point)
        case .pencil:
            let radius = CGFloat(max(4, (Int(stroke.width) + 1) / 2))
            let points = [stroke.start] + stroke.points
            return zip(points, points.dropFirst()).contains { segmentCrossesPointerBox($0, $1, center: point, radius: radius) }
        case .text:
            return stroke.hitsMarker(point) || stroke.hitsTextBorder(point)
        case .mosaic, .highlight: return stroke.rect.insetBy(dx:-tolerance,dy:-tolerance).contains(point)
        case .ellipse:
            let r=stroke.rect,rx=r.width/2,ry=r.height/2,dx=point.x-r.midX,dy=point.y-r.midY
            guard rx>0,ry>0 else{return false}
            let innerX=rx-tolerance,innerY=ry-tolerance
            let outer=dx*dx/((rx+tolerance)*(rx+tolerance))+dy*dy/((ry+tolerance)*(ry+tolerance))
            if stroke.filled{return dx*dx/(rx*rx)+dy*dy/(ry*ry)<1}
            let inner=innerX>0 && innerY>0 ? dx*dx/(innerX*innerX)+dy*dy/(innerY*innerY) : .infinity
            return outer<=1 && inner>=1
        case .rectangle:
            return stroke.rect.insetBy(dx:-tolerance,dy:-tolerance).contains(point) && (stroke.filled || !stroke.rect.insetBy(dx:tolerance,dy:tolerance).contains(point))
        default:
            let points = stroke.tool == .pencil ? [stroke.start]+stroke.points : [stroke.start,stroke.end]
            return zip(points,points.dropFirst()).contains { a,b in
                let dx=b.x-a.x,dy=b.y-a.y,l2=dx*dx+dy*dy
                let t=l2==0 ? 0 : max(0,min(1,((point.x-a.x)*dx+(point.y-a.y)*dy)/l2))
                return hypot(point.x-a.x-t*dx,point.y-a.y-t*dy)<=tolerance
            } || path(stroke).contains(point)
        }
    }
}

/// 按逻辑尺寸与像素倍率生成缩小的效果底图，再映射回标注画布。
@MainActor final class ScreenshotEditorEffects {
    let base:NSImage
    private var cached:[Int:NSImage]=[:]
    private lazy var reduced:CGImage? = {
        var rect=NSRect(origin:.zero,size:base.size)
        guard let image=base.cgImage(forProposedRect:&rect,context:nil,hints:nil),
              let space=NSColorSpace.genericRGB.cgColorSpace else{return nil}
        let backingScale=CGFloat(image.width)/base.size.width
        let factor=CGFloat(Float(1/backingScale)*0.5)
        let width=max(1,Int(base.size.width*factor)),height=max(1,Int(base.size.height*factor))
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo: .init(alpha: .premultipliedFirst, byteOrder: .order32Little)) else{return nil}
        context.draw(image,in:CGRect(x:0,y:0,width:base.size.width*factor,height:base.size.height*factor))
        return context.makeImage()
    }()
    init(base:NSImage){self.base=base}
    func image(level:Int,blurred:Bool)->NSImage? {
        let level=max(1,min(10,level)),key=level+(blurred ? 10 : 0)
        if let image=cached[key]{return image}
        guard let reduced else{return nil}
        let input:CIImage
        if blurred {input=CIImage(cgImage:reduced)} else {
            let image=NSImage(cgImage:reduced,size:NSSize(width:reduced.width,height:reduced.height))
            guard let data=image.tiffRepresentation,let ci=CIImage(data:data) else{return nil}
            input=ci
        }
        var output=input
        if blurred,level>1 {
            guard let clamp=CIFilter(name:"CIAffineClamp"),let blur=CIFilter(name:"CIGaussianBlur") else{return nil}
            clamp.setValue(input,forKey:kCIInputImageKey)
            var transform=CGAffineTransform.identity
            clamp.setValue(NSValue(bytes:&transform,objCType:"{CGAffineTransform=dddddd}"),forKey:kCIInputTransformKey)
            blur.setValue(clamp.outputImage,forKey:kCIInputImageKey)
            blur.setValue(Float(ScreenshotEditorGeometry.filterRadius(level:level)),forKey:kCIInputRadiusKey)
            guard let image=blur.outputImage else{return nil};output=image
        } else if !blurred {
            guard let pixelate=CIFilter(name:"CIPixellate") else{return nil}
            pixelate.setValue(input,forKey:kCIInputImageKey);pixelate.setValue(level,forKey:kCIInputScaleKey)
            guard let image=pixelate.outputImage else{return nil};output=image
        }
        guard let cg=CIContext(options:nil).createCGImage(output,from:input.extent) else{return nil}
        let image=NSImage(cgImage:cg,size:base.size);cached[key]=image;return image
    }
}

@MainActor enum ScreenshotEditorRenderer {
    static func draw(_ stroke: ScreenshotEditorStroke, base: NSImage, effects: ScreenshotEditorEffects? = nil, effectOrigin: CGPoint = .zero) {
        stroke.color.withAlphaComponent(stroke.tool == .line || stroke.tool == .arrow ? 1 : stroke.opacity).set()
        let path = ScreenshotEditorGeometry.path(stroke)
        path.lineWidth = stroke.width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        if stroke.dashed { path.setLineDash([stroke.width * 2, stroke.width * 2], count: 2, phase: 0) }
        switch stroke.tool {
        case .text:
            ScreenshotAnnotationRendering.drawMarker(stroke)
            if !stroke.isEditingPreview { ScreenshotEditorTextRendering.draw(stroke) }
        case .mosaic:
            guard let image=(effects ?? ScreenshotEditorEffects(base:base)).image(level:Int(stroke.width),blurred:stroke.blurred) else{return}
            image.draw(in: stroke.rect, from: stroke.rect.offsetBy(dx: effectOrigin.x, dy: effectOrigin.y), operation: .sourceOver, fraction: 1)
        case .highlight: drawFocus(stroke, size: base.size)
        case .pencil where stroke.pencilMode == .highlighter:
            stroke.color.withAlphaComponent(stroke.opacity).setFill(); path.fill()
        case .arrow where stroke.arrowStyle != .solid:
            stroke.color.withAlphaComponent(1).set()
            path.stroke()
            let head = ScreenshotEditorGeometry.arrowHead(stroke)
            head.lineWidth = stroke.width; head.lineCapStyle = .round; head.lineJoinStyle = .round
            head.stroke()
        case .arrow where stroke.curved:
            stroke.color.withAlphaComponent(1).set(); path.stroke(); let points=ScreenshotEditorGeometry.curveHead(end:stroke.end,control2:stroke.control2 ?? stroke.start,width:stroke.width)
            if let first=points.first { let head=NSBezierPath();head.move(to:first);points.dropFirst().forEach(head.line);head.close();head.fill() }
        case .arrow: stroke.color.withAlphaComponent(1).set(); path.fill()
        case .rectangle,.ellipse:
            switch stroke.shapeMode {
            case .outline: path.stroke()
            case .fill:
                path.fill()
                stroke.color.withAlphaComponent(1).setStroke()
                path.stroke()
            case .solid:
                stroke.color.withAlphaComponent(1).setFill()
                path.fill()
            }
        default: path.stroke()
        }
    }
    /// 聚焦和其他对象一样按创建顺序叠放，后创建的内容绘制在其上方。
    static func drawFocus(_ stroke: ScreenshotEditorStroke, size: NSSize) {
        let mask = NSBezierPath(rect: CGRect(origin: .zero, size: size))
        let radius = min(stroke.cornerRadius, min(stroke.rect.width, stroke.rect.height) / 2)
        let cutout = stroke.focusIsEllipse ? NSBezierPath(ovalIn: stroke.rect) : NSBezierPath(roundedRect: stroke.rect, xRadius: radius, yRadius: radius)
        mask.append(cutout); mask.windingRule = .evenOdd
        Design.ScreenshotEditor.highlightFill.withAlphaComponent(stroke.opacity).setFill()
        mask.fill()
    }
    static func image(base:NSImage,strokes:[ScreenshotEditorStroke],effects:ScreenshotEditorEffects? = nil,effectOrigin:CGPoint = .zero,cornerRadiusPixels: CGFloat = 0) -> NSImage {
        var proposed=NSRect(origin:.zero,size:base.size)
        let source=base.cgImage(forProposedRect:&proposed,context:nil,hints:nil)
        let pixelWidth=source?.width ?? Int(base.size.width),pixelHeight=source?.height ?? Int(base.size.height)
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixelWidth,pixelsHigh:pixelHeight,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let context=NSGraphicsContext(bitmapImageRep:bitmap) else{return base}
        bitmap.size=base.size
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.cgContext.scaleBy(x:CGFloat(pixelWidth)/base.size.width,y:CGFloat(pixelHeight)/base.size.height)
        let radius = min(max(0, cornerRadiusPixels), (CGFloat(min(pixelWidth, pixelHeight)) / 2).rounded(.down))
        if radius > 0 {
            NSBezierPath(roundedRect: CGRect(origin: .zero, size: base.size), xRadius: radius * base.size.width / CGFloat(pixelWidth), yRadius: radius * base.size.height / CGFloat(pixelHeight)).addClip()
        }
        base.draw(at:.zero,from:.zero,operation:.copy,fraction:1)
        let effects = effects ?? ScreenshotEditorEffects(base: base)
        for stroke in strokes { draw(stroke, base: base, effects: effects, effectOrigin: effectOrigin) }
        NSGraphicsContext.restoreGraphicsState()
        let output=NSImage(size:base.size);output.addRepresentation(bitmap);return output
    }
}
