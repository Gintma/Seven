import AppKit
import XCTest
@testable import Seven

@MainActor final class ScreenshotUndoTests: XCTestCase {
    private func stroke() -> ScreenshotEditorStroke {
        var stroke = ScreenshotEditorStroke(id: UUID(), tool: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 70, y: 70), color: .red, width: 3, opacity: 0)
        stroke.shapeMode = .fill
        return stroke
    }
    func testContinuousChangesAreOneUndoAndRedoStep() {
        var document = ScreenshotEditorDocument()
        let original = stroke(); document.commit(original); document.beginOperation()
        for value in 1...100 {
            var changed = original; changed.opacity = CGFloat(value)/100; document.commit(changed)
            XCTAssertEqual(document.visible.first?.opacity, changed.opacity)
            XCTAssertEqual(document.history.count, 1)
        }
        document.endOperation()
        XCTAssertEqual(document.history.count, 2)
        document.undo(); XCTAssertEqual(document.visible, [original])
        document.redo(); XCTAssertEqual(document.visible.first?.opacity, 1)
    }
    func testReturningToOriginalValuePreservesRedoAndDoesNotAddHistory() {
        var document = ScreenshotEditorDocument()
        let original = stroke(); var changed = original; changed.opacity = 1
        document.commit(original); document.commit(changed); document.undo()
        document.beginOperation(); document.commit(changed); XCTAssertFalse(document.canRedo)
        document.commit(original); XCTAssertTrue(document.canRedo); document.endOperation()
        XCTAssertEqual(document.history.count, 2); XCTAssertTrue(document.canRedo)
        document.redo(); XCTAssertEqual(document.visible, [changed])
        document.commit(changed); XCTAssertEqual(document.history.count, 2)
        document.undo(); document.beginOperation(); changed.width = 12; document.commit(changed); document.endOperation()
        XCTAssertFalse(document.canRedo)
    }
    private func editor() throws -> (ScreenshotEditorWindowController, ScreenshotEditorCanvas, ScreenshotValueSlider) {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 160, bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let controller = makeScreenshotEditorForTesting(image: NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 200, height: 160)), preferences: ScreenshotToolPreferences())
        let views = try screenshotEditorTestSubviews(controller)
        let canvas = try XCTUnwrap(views.compactMap { $0 as? ScreenshotEditorCanvas }.first)
        let slider = try XCTUnwrap(views.compactMap { $0 as? ScreenshotValueSlider }.first { $0.accessibilityLabel() == "标注不透明度" })
        let original = stroke(); canvas.document.commit(original); canvas.selected = original.id
        canvas.tool = .rectangle; canvas.filled = true; canvas.fillHasBorder = true; canvas.opacity = 0
        canvas.onChange?()
        return (controller, canvas, slider)
    }
    func testSliderGestureAndToolbarValuesFollowUndoAndRedo() throws {
        let (controller, canvas, slider) = try editor(); defer { controller.close() }
        slider.onEditingBegan?()
        for value in 1...100 {
            slider.doubleValue = Double(value)/100
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(slider.action), to: slider.target, from: slider))
        }
        slider.onEditingEnded?()
        XCTAssertEqual(canvas.document.history.count, 2)
        canvas.undoEdit(); XCTAssertEqual(slider.doubleValue, 0); XCTAssertEqual(slider.toolTip, "不透明度：0%"); XCTAssertEqual(canvas.document.visible.first?.opacity, 0)
        canvas.redoEdit(); XCTAssertEqual(slider.doubleValue, 1); XCTAssertEqual(canvas.document.visible.first?.opacity, 1)
    }
    func testPaletteTrialColorsAreOneOperation() throws {
        let (controller, canvas, _) = try editor(); defer { controller.close() }
        let well = try XCTUnwrap(try screenshotEditorTestSubviews(controller).compactMap { $0 as? ColorSelectionWell }.first)
        well.onEditingBegan?(); well.color = .green; well.color = .blue; well.onEditingEnded?()
        XCTAssertEqual(canvas.document.history.count, 2)
        canvas.undoEdit(); XCTAssertEqual(canvas.document.visible.first?.color, .red)
        canvas.redoEdit(); XCTAssertEqual(canvas.document.visible.first?.color, .blue)
    }
    func testTextTypingAndFontGestureAreSeparateOperationsWithoutEmptyTextCommit() throws {
        let canvas = ScreenshotEditorCanvas(image: NSImage(size: CGSize(width: 500, height: 400)))
        canvas.tool = .text
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 80, y: 240), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: event)
        let text = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        text.string = "完整文字"; canvas.textDidChange(Notification(name: NSText.didChangeNotification))
        canvas.beginParameterChange()
        let initialSize = try XCTUnwrap(canvas.document.history.last?.width)
        for size in [30.0, 40.0, 50.0] { canvas.updateSelected { $0.width = size } }
        canvas.endParameterChange(); canvas.commitText()
        XCTAssertEqual(canvas.document.history.count, 2)
        XCTAssertEqual(canvas.document.visible.first?.text, "完整文字")
        canvas.undoEdit(); XCTAssertEqual(canvas.document.visible.first?.width, initialSize)
        XCTAssertEqual(canvas.document.visible.first?.text, "完整文字")
        canvas.redoEdit(); XCTAssertEqual(canvas.document.visible.first?.width, 50)
    }
    func testTextResizeIsSeparateFromTypingAndOpeningWithoutChangesIsNotAnEdit() throws {
        let canvas = ScreenshotEditorCanvas(image: NSImage(size: CGSize(width: 500, height: 400)))
        canvas.tool = .text
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 80, y: 240), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: event)
        let text = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        text.string = "一段文字"; canvas.textDidChange(Notification(name: NSText.didChangeNotification))
        let chrome = try XCTUnwrap(canvas.subviews.compactMap { $0 as? ScreenshotTextEditorChrome }.first)
        chrome.onResizeBegan?(false)
        let before = try XCTUnwrap(canvas.document.history.last)
        chrome.onResize?(40); chrome.onResize?(80); chrome.onResizeEnded?()
        canvas.commitText()
        XCTAssertEqual(canvas.document.history.count, 2)
        canvas.undoEdit(); XCTAssertEqual(canvas.document.visible, [before])
        canvas.redoEdit()
        let final = try XCTUnwrap(canvas.document.visible.first)
        let open = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: final.rect.midX, y: final.rect.midY), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        canvas.mouseDown(with: open); canvas.commitText()
        XCTAssertEqual(canvas.document.history.count, 2, "仅打开再关闭文本不能增加历史")
    }

}

extension ScreenshotUndoTests {
    func testDeletingSelectionIsOneUndoStepForBothDeleteKeys() throws {
        let canvas = ScreenshotEditorCanvas(image: NSImage(size: CGSize(width: 200, height: 160)))
        for code: UInt16 in [51, 117] {
            canvas.document = ScreenshotEditorDocument()
            let first = stroke()
            let second = stroke()
            canvas.document.commit(first)
            canvas.document.commit(second)
            canvas.selected = first.id
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
            canvas.keyDown(with: event)
            XCTAssertEqual(canvas.document.visible.map(\.id), [second.id])
            canvas.undoEdit()
            XCTAssertEqual(canvas.document.visible.map(\.id), [first.id, second.id])
            canvas.redoEdit()
            XCTAssertEqual(canvas.document.visible.map(\.id), [second.id])
        }
    }

    func testEditingPreviewUndoRedoAndBranchKeepFirstCreationOrder() {
        var document = ScreenshotEditorDocument()
        var first = stroke()
        var focus = stroke()
        focus.tool = .highlight
        var last = stroke()
        last.tool = .arrow
        for stroke in [first, focus, last] { document.commit(stroke) }
        let order = [first.id, focus.id, last.id]
        first.color = .blue; document.commit(first)
        XCTAssertEqual(document.visible.map(\.id), order)
        var preview = focus; preview.translate(CGPoint(x: 20, y: 20)); document.preview = preview
        XCTAssertEqual(document.visible.map(\.id), order)
        XCTAssertEqual(document.visible[1].start, preview.start)
        document.undo(); XCTAssertEqual(document.visible.map(\.id), order); XCTAssertEqual(document.visible[0].color, .red)
        document.redo(); XCTAssertEqual(document.visible.map(\.id), order); XCTAssertEqual(document.visible[0].color, .blue)
        document.undo(); let added = stroke(); document.commit(added)
        XCTAssertEqual(document.visible.map(\.id), order + [added.id]); XCTAssertFalse(document.canRedo)
    }
}
