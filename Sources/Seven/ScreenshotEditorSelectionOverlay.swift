import AppKit

/// Keeps the frozen screen after selection mouseUp; the annotation toolbar floats independently while the selection frame continues accepting moves and 8-way resize.
@MainActor final class ScreenshotEditorSelectionOverlay: NSView {
    let context: FrozenSelectionContext
    let canvas: ScreenshotEditorCanvas
    private(set) var selection: CGRect
    private(set) var aspectRatio: ScreenshotAspectRatio = .free
    var onSelectionChanged: (() -> Void)?
    var onInteraction: (() -> Void)?
    private var baseline = CGRect.zero
    private var anchor = CGPoint.zero
    private var previousPoint = CGPoint.zero
    private var chrome: ScreenshotEditorSelectionChrome?
    private var handle: FrozenSelectionHandle?
    private var moving = false
    private var creating = false
    private var pointerTracking: NSTrackingArea?
    private var frozen: NSImage
    private let background: NSImage

    var globalSelection: CGRect { selection.offsetBy(dx: context.screenFrame.minX, dy: context.screenFrame.minY) }

    init(context: FrozenSelectionContext, canvas: ScreenshotEditorCanvas) {
        self.context = context
        self.canvas = canvas
        self.selection = context.localSelection
        self.frozen = NSImage(cgImage: context.image, size: context.screenFrame.size)
        self.background = NSImage(cgImage: context.backgroundImage ?? context.image, size: context.screenFrame.size)
        super.init(frame: CGRect(origin: .zero, size: context.screenFrame.size))
        canvas.useFrozenEffects(frozen, origin: selection.origin)
        canvas.frame = selection
        addSubview(canvas)
        canvas.onRegionDragBegan = { [weak self] event in self?.beginMovingRegion(event) }
        canvas.onRegionDragged = { [weak self] event in self?.mouseDragged(with: event) }
        canvas.onRegionDragEnded = { [weak self] event in self?.mouseUp(with: event) }
        let chrome = ScreenshotEditorSelectionChrome()
        chrome.frame = bounds; chrome.autoresizingMask = [.width, .height]
        chrome.selection = selection
        chrome.cornerRadii = canvas.outputCornerRadii
        addSubview(chrome)
        self.chrome = chrome
        setAccessibilityLabel(L10n.text("screenshotSelectionDragTheBorderOrAny"))
    }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        FrozenCaptureMask.draw(background: background, in: bounds, revealing: context.isWindowComposition ? [] : [selection], cornerRadii: canvas.outputCornerRadii)
    }
    private func selectedHandle(at point: CGPoint) -> FrozenSelectionHandle? {
        FrozenSelectionHandle.allCases.first {
            let handle = $0.point(in: selection)
            return abs(point.x - handle.x) <= Design.ScreenshotEditor.handleSize && abs(point.y - handle.y) <= Design.ScreenshotEditor.handleSize
        }
    }
    private func onBorder(_ point: CGPoint) -> Bool {
        let tolerance = Design.ScreenshotEditor.handleSize / 2
        return selection.insetBy(dx: -tolerance, dy: -tolerance).contains(point) && !selection.insetBy(dx: tolerance, dy: tolerance).contains(point)
    }
    private func resizeCursor(_ handle: FrozenSelectionHandle) -> NSCursor {
        switch handle {
        case .left, .right: return ScreenshotEditCursor.horizontal.cursor
        case .top, .bottom: return ScreenshotEditCursor.vertical.cursor
        case .topRight, .bottomLeft: return ScreenshotEditCursor.diagonalUp.cursor
        case .topLeft, .bottomRight: return ScreenshotEditCursor.diagonalDown.cursor
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking); pointerTracking = tracking
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !selection.contains(point) { NSCursor.arrow.set() }
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    override func resetCursorRects() {
        let t = Design.ScreenshotEditor.handleSize
        // Register native arrow cursor rects for the surrounding backdrop rather than relying solely on mouseMoved to override the previous hand cursor.
        let outside = [
            CGRect(x: bounds.minX, y: bounds.minY, width: selection.minX - bounds.minX, height: bounds.height),
            CGRect(x: selection.maxX, y: bounds.minY, width: bounds.maxX - selection.maxX, height: bounds.height),
            CGRect(x: selection.minX, y: bounds.minY, width: selection.width, height: selection.minY - bounds.minY),
            CGRect(x: selection.minX, y: selection.maxY, width: selection.width, height: bounds.maxY - selection.maxY)
        ]
        for rect in outside where !rect.isEmpty { addCursorRect(rect.intersection(bounds), cursor: .arrow) }
        for strip in [CGRect(x: selection.minX, y: selection.minY, width: selection.width, height: t), CGRect(x: selection.minX, y: selection.maxY-t, width: selection.width, height: t), CGRect(x: selection.minX, y: selection.minY, width: t, height: selection.height), CGRect(x: selection.maxX-t, y: selection.minY, width: t, height: selection.height)] { addCursorRect(strip, cursor: .openHand) }
        for handle in FrozenSelectionHandle.allCases {
            let point = handle.point(in: selection)
            addCursorRect(CGRect(x: point.x-t, y: point.y-t, width: t*2, height: t*2).intersection(selection), cursor: resizeCursor(handle))
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if selectedHandle(at: point) != nil || onBorder(point) { return self }
        return super.hitTest(point)
    }
    private func beginMovingRegion(_ event: NSEvent) {
        onInteraction?(); canvas.commitText()
        anchor = convert(event.locationInWindow, from: nil)
        baseline = selection; previousPoint = FrozenSelectionGeometry.movingAnchor(for: anchor)
        moving = true; creating = false; handle = nil
    }
    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        canvas.commitText(); canvas.selected = nil
        anchor = convert(event.locationInWindow, from: nil)
        baseline = selection
        previousPoint = FrozenSelectionGeometry.movingAnchor(for: anchor)
        handle = selectedHandle(at: anchor)
        moving = handle == nil && onBorder(anchor)
        creating = handle == nil && !moving
        if let handle { resizeCursor(handle).set() } else if moving { NSCursor.closedHand.set() }
    }
    override func mouseDragged(with event: NSEvent) {
        onInteraction?()
        let point = convert(event.locationInWindow, from: nil)
        let changed: CGRect
        if let handle {
            resizeCursor(handle).set()
            changed = ScreenshotSelectionSizing.dragged(baseline, handle: handle, to: point, ratio: aspectRatio, context: context)
        } else if moving {
            NSCursor.closedHand.set()
            changed = FrozenSelectionGeometry.moved(selection, from: previousPoint, to: point, within: bounds.size)
            previousPoint = FrozenSelectionGeometry.movingAnchor(for: point)
        } else if creating {
            let initial = CGRect(origin: anchor, size: .zero)
            changed = ScreenshotSelectionSizing.dragged(initial, handle: .topRight, to: point, ratio: aspectRatio, context: context)
        } else { return }
        replaceSelection(changed)
        if !selection.contains(point) { NSCursor.arrow.set() }
    }
    override func mouseUp(with event: NSEvent) {
        handle = nil; moving = false; creating = false
        let point = convert(event.locationInWindow, from: nil)
        if selection.contains(point) { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
    }
    func refreshCornerAppearance() { chrome?.cornerRadii = canvas.outputCornerRadii; needsDisplay = true }
    var pixelSize: CGSize { ScreenshotSelectionSizing.pixelSize(selection, context: context) }
    func setPixelSize(width: Int? = nil, height: Int? = nil) {
        replaceSelection(ScreenshotSelectionSizing.resized(selection, width: width, height: height, ratio: aspectRatio, context: context))
    }
    func setAspectRatio(_ ratio: ScreenshotAspectRatio) {
        aspectRatio = ratio
        if ratio != .free { replaceSelection(ScreenshotSelectionSizing.resized(selection, ratio: ratio, context: context)) }
    }
    func replaceSelection(_ rect: CGRect) {
        guard rect.width > 0, rect.height > 0, rect != selection,
              let image = context.croppedImage(in: rect) else { return }
        let delta = CGPoint(x: selection.minX - rect.minX, y: selection.minY - rect.minY)
        canvas.replaceImage(image, rebasing: delta)
        selection = rect
        chrome?.selection = rect
        chrome?.cornerRadii = canvas.outputCornerRadii
        canvas.frame = rect
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onSelectionChanged?()
    }
    override func rightMouseDown(with event: NSEvent) { canvas.onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { canvas.onCancel?() } else { super.keyDown(with: event) }
    }
}

final class ScreenshotEditorOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class ScreenshotEditorSelectionChrome: ThemedDrawingView {
    var selection = CGRect.zero { didSet { needsDisplay = true } }
    var cornerRadii = CGSize.zero { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        theme.captureAccent.setStroke()
        let border = NSBezierPath(roundedRect: selection, xRadius: cornerRadii.width, yRadius: cornerRadii.height)
        border.lineWidth = Design.ScreenshotCapture.borderWidth
        border.stroke()
        for handle in FrozenSelectionHandle.allCases {
            let point = handle.point(in: selection), size = Design.ScreenshotEditor.handleSize
            theme.captureAccent.setFill()
            NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size).fill()
        }
    }
}
