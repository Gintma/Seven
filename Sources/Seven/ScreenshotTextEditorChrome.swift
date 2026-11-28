import AppKit

/// Shown only while positioning and typing; excluded from the document and image renderer so it never appears in copied or saved output.
final class ScreenshotTextEditorChrome: ThemedDrawingView {
    var onResizeBegan: ((Bool) -> Void)?
    var onResize: ((CGFloat) -> Void)?
    var onResizeEnded: (() -> Void)?
    var onMoveBegan: (() -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onMoveEnded: (() -> Void)?
    private var moving = false
    private var initialPoint = CGPoint.zero
    private var initialX: CGFloat = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ parentPoint: NSPoint) -> NSView? {
        let point = convert(parentPoint, from: superview)
        let rect = bounds.insetBy(dx: Design.AnnotationEditor.borderWidth, dy: Design.AnnotationEditor.borderWidth)
        let handle = abs(point.y - rect.midY) <= Design.AnnotationEditor.handleHeight && min(abs(point.x - rect.minX), abs(point.x - rect.maxX)) <= Design.ScreenshotEditor.handleSize
        let border = rect.insetBy(dx: -Design.ScreenshotEditor.handleSize / 2, dy: -Design.ScreenshotEditor.handleSize / 2).contains(point) && !rect.insetBy(dx: Design.ScreenshotEditor.handleSize / 2, dy: Design.ScreenshotEditor.handleSize / 2).contains(point)
        return handle || border ? self : nil
    }
    override func resetCursorRects() {
        let thickness = Design.ScreenshotEditor.handleSize
        let rect = bounds.insetBy(dx: Design.AnnotationEditor.borderWidth, dy: Design.AnnotationEditor.borderWidth)
        for strip in [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: thickness), CGRect(x: rect.minX, y: rect.maxY-thickness, width: rect.width, height: thickness), CGRect(x: rect.minX, y: rect.minY, width: thickness, height: rect.height), CGRect(x: rect.maxX-thickness, y: rect.minY, width: thickness, height: rect.height)] {
            addCursorRect(strip, cursor: .openHand)
        }
        for x in [rect.minX, rect.maxX] {
            addCursorRect(CGRect(x: x-thickness, y: rect.midY-Design.AnnotationEditor.handleHeight, width: thickness*2, height: Design.AnnotationEditor.handleHeight*2), cursor: ScreenshotEditCursor.horizontal.cursor)
        }
    }
    override func mouseDown(with event: NSEvent) {
        initialPoint = event.locationInWindow; initialX = initialPoint.x
        let point = convert(event.locationInWindow, from: nil)
        moving = abs(point.y-bounds.midY) > Design.AnnotationEditor.handleHeight
        if moving { NSCursor.closedHand.set(); onMoveBegan?() }
        else { ScreenshotEditCursor.horizontal.cursor.set(); onResizeBegan?(point.x < bounds.midX) }
    }
    override func mouseDragged(with event: NSEvent) {
        if moving {
            NSCursor.closedHand.set()
            onMove?(CGPoint(x: event.locationInWindow.x-initialPoint.x, y: event.locationInWindow.y-initialPoint.y))
        } else { ScreenshotEditCursor.horizontal.cursor.set(); onResize?(event.locationInWindow.x-initialX) }
    }
    override func mouseUp(with event: NSEvent) {
        if moving { onMoveEnded?(); NSCursor.openHand.set() }
        else { onResizeEnded?(); ScreenshotEditCursor.horizontal.cursor.set() }
    }
    override func draw(_ dirtyRect: NSRect) {
        let width = Design.AnnotationEditor.borderWidth
        let rect = bounds.insetBy(dx: width, dy: width)
        theme.accent.setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: Design.AnnotationEditor.radius, yRadius: Design.AnnotationEditor.radius)
        path.lineWidth = width; path.stroke()
        for x in [rect.minX, rect.maxX] {
            theme.annotationHandle.setFill()
            let handle = NSBezierPath(roundedRect: CGRect(x: x - Design.AnnotationEditor.handleWidth, y: rect.midY - Design.AnnotationEditor.handleHeight / 2, width: Design.AnnotationEditor.handleWidth * 2, height: Design.AnnotationEditor.handleHeight), xRadius: Design.AnnotationEditor.handleWidth, yRadius: Design.AnnotationEditor.handleWidth)
            handle.fill(); handle.stroke()
        }
    }
}
