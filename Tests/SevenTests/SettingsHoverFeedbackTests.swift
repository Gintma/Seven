import AppKit
import XCTest
@testable import Seven

@MainActor
final class SettingsHoverFeedbackTests: XCTestCase {
    func testScrollingUnderStationaryPointerClearsPreviousRowHighlight() throws {
        _ = NSApplication.shared
        let window = PointerWindow(contentRect: CGRect(x: 0, y: 0, width: 160, height: 100),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 160, height: 100))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 160, height: 200))
        window.contentView = scroll
        scroll.documentView = document
        let clip = scroll.contentView
        let first = SettingsHoverFeedbackView(frame: CGRect(x: 0, y: 62, width: 160, height: 30))
        let second = SettingsHoverFeedbackView(frame: CGRect(x: 0, y: 106, width: 160, height: 30))
        document.addSubview(first)
        document.addSubview(second)

        let entered = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: window.mouseLocationOutsideOfEventStream,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        first.mouseEntered(with: entered)
        XCTAssertTrue(try drawsHighlight(first))
        XCTAssertFalse(try drawsHighlight(second))

        // 滚轮移动内容时，上一行可能没有收到 mouseExited。
        clip.scroll(to: CGPoint(x: 0, y: 44))
        first.updateTrackingAreas()
        second.updateTrackingAreas()
        second.mouseEntered(with: entered)
        XCTAssertFalse(try drawsHighlight(first), "上一行仍可见，但指针已经不在该行")
        XCTAssertTrue(try drawsHighlight(second))

        clip.scroll(to: CGPoint(x: 0, y: 70))
        second.updateTrackingAreas()
        XCTAssertFalse(try drawsHighlight(second), "指针落在空白处时不应保留悬停底色")
        second.mouseEntered(with: entered)
        XCTAssertFalse(try drawsHighlight(second), "滚动前排队的进入事件不能恢复旧的悬停底色")
    }

    private func drawsHighlight(_ view: SettingsHoverFeedbackView) throws -> Bool {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 30, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(view.bounds)
        view.draw(view.bounds)
        return try XCTUnwrap(bitmap.colorAt(x: 80, y: 15)).alphaComponent > 0
    }

    private final class PointerWindow: NSWindow {
        override var mouseLocationOutsideOfEventStream: NSPoint { NSPoint(x: 80, y: 75) }
    }
}
