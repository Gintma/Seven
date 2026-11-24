import AppKit

/// 长图居中与钉图原位共用覆盖层/标注画布；界面位置、缩放与导出像素分离。
struct ScreenshotCenteredEditorContext {
    let screenFrame: CGRect
    let background: CGImage?
    var placement: CGRect? = nil
    func displayedSize(for image: NSImage) -> CGSize {
        if let placement { return placement.size }
        let inset = Design.ScreenshotScroll.editorInset
        let available = CGSize(width: max(1, screenFrame.width-inset*2), height: max(1, screenFrame.height-inset*2))
        let factor = min(1, available.width/max(1,image.size.width), available.height/max(1,image.size.height))
        return CGSize(width: image.size.width*factor, height: image.size.height*factor)
    }
}

@MainActor final class ScreenshotCenteredEditorOverlay: NSView {
    let selection: CGRect
    init(context: ScreenshotCenteredEditorContext, canvas: ScreenshotEditorCanvas) {
        selection = context.placement.map { $0.offsetBy(dx:-context.screenFrame.minX,dy:-context.screenFrame.minY) }
            ?? CGRect(x: (context.screenFrame.width-canvas.bounds.width)/2, y: (context.screenFrame.height-canvas.bounds.height)/2, width: canvas.bounds.width, height: canvas.bounds.height)
        background = context.background.map { NSImage(cgImage: $0, size: context.screenFrame.size) }
        super.init(frame: CGRect(origin: .zero, size: context.screenFrame.size))
        let logicalSize=canvas.bounds.size
        canvas.frame = selection
        if context.placement != nil { canvas.setBoundsSize(logicalSize) }
        addSubview(canvas)
    }
    private let background: NSImage?
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        background?.draw(in: bounds)
        Design.ScreenshotCapture.maskFill.setFill()
        bounds.fill()
    }
}
