import AppKit
import VisionKit

/// 原图只在内存中显示：滚轮围绕指针缩放，左键平移，右键恢复适应面板。
final class OCRImagePreview: NSView, ImageAnalysisOverlayViewDelegate {
    private(set) var image: NSImage?
    private let imageSize: NSSize
    private(set) var zoom: CGFloat = 1
    private(set) var offset = CGPoint.zero
    private var dragPoint: CGPoint?
    private var didPan = false
    private let imageView = NSImageView()
    let textOverlay = ImageAnalysisOverlayView()
    private let analyzer: any OCRImageAnalyzing
    private let clipboardWriter: (String) -> Bool
    private var analysisTask: Task<Void, Never>?
    private var analysisGeneration = UUID()
    private var analyzedLanguage: String?
    private var presentationActive = true
    private var pointerTracking: NSTrackingArea?
    var recognitionLanguage = LanguageCatalog.automatic {
        didSet {
            guard oldValue != recognitionLanguage else { return }
            cancelAnalysis(); analyzedLanguage = nil; textOverlay.analysis = nil
            beginAnalysisIfNeeded()
        }
    }
    var onMenuTrackingChange: ((Bool) -> Void)?
    private(set) var isAnalyzing = false


    init(image: NSImage, analyzer: (any OCRImageAnalyzing)? = nil, clipboardWriter: ((String) -> Bool)? = nil) {
        self.image = image; self.imageSize = image.size; self.analyzer = analyzer ?? SystemOCRImageAnalyzer()
        self.clipboardWriter = clipboardWriter ?? { text in
            NSPasteboard.general.clearContents(); return NSPasteboard.general.setString(text, forType: .string)
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        imageView.image = image; imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityLabel(L10n.text("originalImageSelectTextToCopyDrag"))
        addSubview(imageView)
        textOverlay.delegate = self; textOverlay.trackingImageView = imageView
        textOverlay.preferredInteractionTypes = .textSelection
        textOverlay.isSupplementaryInterfaceHidden = true
        imageView.addSubview(textOverlay)
    }
    func refreshInterfaceLanguage() {
        imageView.setAccessibilityLabel(L10n.text("originalImageSelectTextToCopyDrag"))
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var displayedImageRect: CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = NSSize(width: imageSize.width * fit * zoom, height: imageSize.height * fit * zoom)
        return CGRect(x: bounds.midX - size.width / 2 + offset.x, y: bounds.midY - size.height / 2 + offset.y,
                      width: size.width, height: size.height)
    }
    override func layout() {
        super.layout(); updateImageGeometry()
    }
    private func updateImageGeometry() {
        imageView.frame = displayedImageRect
        textOverlay.frame = imageView.bounds
        textOverlay.setContentsRectNeedsUpdate()
        imageView.layoutSubtreeIfNeeded()
        window?.invalidateCursorRects(for: self)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { beginAnalysisIfNeeded() }
        else { cancelAnalysis() }
    }
    func beginAnalysisIfNeeded() {
        guard presentationActive, window != nil, image != nil,
              analyzedLanguage != recognitionLanguage, analysisTask == nil else { return }
        let token = UUID(), language = recognitionLanguage
        analysisGeneration = token; isAnalyzing = true
        analysisTask = Task { [weak self, analyzer] in
            do {
                // 大图原件只在准备副本期间使用。VisionKit 即使延迟响应取消，也只会持有副本。
                let input = try await self?.prepareAnalysisInput()
                try Task.checkCancellation()
                let analysis: ImageAnalysis?
                if let input { analysis = try await analyzer.analyze(input, language: language) }
                else { analysis = nil }
                guard let self, !Task.isCancelled, self.analysisGeneration == token else { return }
                self.textOverlay.analysis = analysis
                self.analyzedLanguage = language; self.analysisTask = nil; self.isAnalyzing = false
                self.updateImageGeometry()
            } catch {
                guard let self, self.analysisGeneration == token else { return }
                self.analysisTask = nil; self.isAnalyzing = false
                // 失败保留图片查看能力；不记录系统可能包含识别内容的错误正文。
            }
        }
    }
    private func prepareAnalysisInput() async throws -> OCRImageAnalysisInput? {
        guard let image else { return nil }
        return try await OCRImageAnalysisInput.prepare(image)
    }
    func cancelAnalysis() {
        analysisGeneration = UUID(); analysisTask?.cancel(); analysisTask = nil; isAnalyzing = false
    }
    func setPresentationActive(_ active: Bool) {
        presentationActive = active
        if active { beginAnalysisIfNeeded() }
        else { cancelAnalysis() }
    }

    var hasActiveTextSelection: Bool { textOverlay.hasActiveTextSelection }

    func replaceDisplayedImage(_ image: NSImage?) {
        cancelAnalysis()
        analyzedLanguage = nil
        textOverlay.analysis = nil
        self.image = image
        imageView.image = image
        updateImageGeometry()
        beginAnalysisIfNeeded()
    }
    /// 系统处理文字命中与选择；空白区域、滚轮和右键仍交给图片视口。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), !isHidden else { return nil }
        switch NSApp.currentEvent?.type {
        case .scrollWheel, .magnify, .rightMouseDown, .rightMouseUp: return self
        default: break
        }
        let overlayPoint = analysisPoint(from: local)
        if textOverlay.hasText(at: overlayPoint) {
            return textOverlay.hitTest(imageView.convert(local, from: self)) ?? self
        }
        return self
    }
    /// VisionKit 的图像命中点以左上为原点；AppKit 视口以左下为原点。
    /// 只转换查询坐标，鼠标事件和原生选择层仍沿用AppKit自己的坐标转换。
    func analysisPoint(from point: CGPoint) -> CGPoint {
        let local = textOverlay.convert(point, from: self)
        return textOverlay.isFlipped ? local : CGPoint(x: local.x, y: textOverlay.bounds.height - local.y)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); pointerTracking = area
    }
    override func resetCursorRects() {
        // 分析后的文字由系统提供 I-beam，空白由cursorUpdate提供小手。
        if textOverlay.analysis == nil { addCursorRect(bounds, cursor: .openHand) }
    }
    override func cursorUpdate(with event: NSEvent) {
        let point = analysisPoint(from: convert(event.locationInWindow, from: nil))
        (textOverlay.hasText(at: point) ? NSCursor.iBeam : NSCursor.openHand).set()
    }
    func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
        if overlayView.hasActiveTextSelection { window?.makeFirstResponder(self) }
    }
    func clearSelectionIfOutside(_ windowPoint: CGPoint) {
        if !bounds.contains(convert(windowPoint, from: nil)) { textOverlay.resetSelection() }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "c",
           !textOverlay.selectedText.isEmpty { return clipboardWriter(textOverlay.selectedText) }
        return super.performKeyEquivalent(with: event)
    }
    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldHandleKeyDownEvent event: NSEvent) -> Bool {
        overlayView.hasActiveTextSelection
    }
    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldBeginAt point: CGPoint,
                     forAnalysisType analysisType: ImageAnalysisOverlayView.InteractionTypes) -> Bool {
        overlayView.hasText(at: point) || overlayView.hasActiveTextSelection
    }
    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldShowMenuForEvent event: NSEvent, atPoint point: CGPoint) -> Bool {
        reset(); return false // 保留用户已确认的右键复原，不另加上下文菜单。
    }
    func overlayView(_ overlayView: ImageAnalysisOverlayView, willOpen menu: NSMenu) { onMenuTrackingChange?(true) }
    func overlayView(_ overlayView: ImageAnalysisOverlayView, didClose menu: NSMenu) { onMenuTrackingChange?(false) }
    override func mouseDown(with event: NSEvent) {
        textOverlay.resetSelection()
        didPan = false
        dragPoint = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let previous = dragPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        didPan = true
        pan(by: CGPoint(x: point.x - previous.x, y: point.y - previous.y))
        dragPoint = point
        NSCursor.closedHand.set()
    }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if dragPoint != nil, !didPan, !displayedImageRect.contains(point) { reset() }
        dragPoint = nil; NSCursor.openHand.set()
    }
    override func scrollWheel(with event: NSEvent) {
        let sensitivity = event.hasPreciseScrollingDeltas ? Design.OCR.preciseZoomSensitivity : Design.OCR.wheelZoomSensitivity
        zoom(by: exp(event.scrollingDeltaY * sensitivity), around: convert(event.locationInWindow, from: nil))
    }
    override func magnify(with event: NSEvent) { zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil)) }
    override func rightMouseDown(with event: NSEvent) { reset() }
    func pan(by delta: CGPoint) { offset.x += delta.x; offset.y += delta.y; updateImageGeometry() }
    func zoom(by factor: CGFloat, around point: CGPoint) {
        let next = min(Design.OCR.maximumZoom, max(Design.OCR.minimumZoom, zoom * factor))
        let ratio = next / zoom
        let center = CGPoint(x: bounds.midX + offset.x, y: bounds.midY + offset.y)
        offset = CGPoint(x: point.x + (center.x - point.x) * ratio - bounds.midX,
                         y: point.y + (center.y - point.y) * ratio - bounds.midY)
        zoom = next; updateImageGeometry()
    }
    func reset() { zoom = 1; offset = .zero; updateImageGeometry() }
}

/// 两块圆角面板之间留白；保留 NSSplitView 原生拖动分栏，不额外画分隔线。
final class OCRResultSplitView: NSSplitView, ThemeApplying {
    private var palette = ThemePalette.system

    override var dividerColor: NSColor { palette.isSystem ? super.dividerColor : palette.separator }

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        needsDisplay = true
    }

    override var dividerThickness: CGFloat { Design.Space.m }
    override func drawDivider(in rect: NSRect) {}
}
