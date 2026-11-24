import AppKit
import Carbon
import XCTest
@testable import Seven

extension StateMachineReproTests {
    func testRepro05_mouseUpAfterUndoDoesNotResurrectAnnotation() throws {
        try checkHistoryShortcutDuringDrag(redo: false)
    }

    func testRepro05_mouseUpAfterRedoDoesNotCommitOldDrag() throws {
        try checkHistoryShortcutDuringDrag(redo: true)
    }

    private func checkHistoryShortcutDuringDrag(redo: Bool) throws {
        _ = NSApplication.shared
        let image = NSImage(cgImage: try sampleImage(), size: CGSize(width: 200, height: 160))
        let editor = makeScreenshotEditorForTesting(
            image: image, preferences: ScreenshotToolPreferences(),
            toolbarPreferences: ScreenshotToolbarPreferences(), clipboardWriter: { _ in false }, soundPlayer: {}
        )
        defer { editor.close() }
        let canvas = try XCTUnwrap(descendants(try XCTUnwrap(editor.window?.contentView)).compactMap {
            $0 as? ScreenshotEditorCanvas
        }.first)
        let inside = CGPoint(x: 40, y: 40)
        let firstDrag = CGPoint(x: 85, y: 55)
        let finalDrag = CGPoint(x: 104, y: 70)
        let stroke = ScreenshotEditorStroke(
            id: UUID(), tool: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 70, y: 70),
            color: .red, width: 3, opacity: 1
        )
        canvas.document.commit(stroke)
        var resized = stroke
        resized.end.x += 12
        if redo {
            canvas.document.commit(resized)
            var moved = resized
            moved.translate(CGPoint(x: 12, y: 0))
            canvas.document.commit(moved)
            canvas.document.undo()
            canvas.document.undo()
        }
        let expected = redo ? [resized] : []
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try mouseEvent(type, at: canvas.convert(point, to: nil), windowNumber: editor.window?.windowNumber ?? 0)
        }

        canvas.mouseDown(with: try mouse(.leftMouseDown, inside))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, firstDrag))
        XCTAssertEqual(canvas.document.preview?.id, stroke.id)
        let modifiers: NSEvent.ModifierFlags = redo ? [.command, .shift] : [.command]
        XCTAssertTrue(editor.performShortcut(try keyEvent("z", code: UInt16(kVK_ANSI_Z), modifiers: modifiers)))
        XCTAssertEqual(canvas.document.visible, expected)
        XCTAssertTrue(canvas.document.canRedo)

        canvas.mouseDragged(with: try mouse(.leftMouseDragged, finalDrag))
        canvas.mouseUp(with: try mouse(.leftMouseUp, finalDrag))

        XCTAssertEqual(canvas.document.visible.map(\.rect), expected.map(\.rect))
        XCTAssertTrue(canvas.document.canRedo)
    }

    private func sampleImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 200, height: 160, bitsPerComponent: 8, bytesPerRow: 800,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags = [], windowNumber: Int = 0
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers, timestamp: 0,
            windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func keyEvent(
        _ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }
}
