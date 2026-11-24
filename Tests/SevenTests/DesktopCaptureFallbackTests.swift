import AppKit
import XCTest
@testable import Seven

@MainActor final class DesktopCaptureFallbackTests: XCTestCase {
    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 240, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 400, height: 240))
        return try XCTUnwrap(context.makeImage())
    }
    private func event(_ type: NSEvent.EventType, _ point: CGPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    func testDesktopHoverRevealsCurrentScreenAndClickSelectsItForEveryCapturePurpose() throws {
        let screen = CGRect(x: -800, y: 200, width: 200, height: 120)
        let suite = "DesktopFallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        for key in [ScreenshotCapturePreferences.crosshairKey, ScreenshotCapturePreferences.magnifierKey, ScreenshotCapturePreferences.hintsKey] { defaults.set(false, forKey: key) }
        for purpose in [FrozenCapturePurpose.screenshot, .ocr, .translation, .scroll] {
            var selected: CGRect?, selectedWindow: FrozenWindowCandidate?
            let view = FrozenSelectionView(frame: CGRect(origin: .zero, size: screen.size), image: try image(), screenFrame: screen, candidates: [], smartSelectionEnabled: true, capturePreferences: ScreenshotCapturePreferences(defaults: defaults), purpose: purpose, fullScreen: {}, previousArea: {}) { selected = $0; selectedWindow = $1 }
            let point = CGPoint(x: 140, y: 60)
            view.refreshHover(at: point)
            XCTAssertEqual(view.selection, view.bounds, "\(purpose)桌面应回退当前屏幕，不能保持空选区")
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let sample = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(min(sample.redComponent, sample.greenComponent, sample.blueComponent), 0.9, "桌面悬停不能被全屏黑色蒙层盖住")
            view.mouseDown(with: try event(.leftMouseDown, point)); view.mouseUp(with: try event(.leftMouseUp, point))
            XCTAssertEqual(selected, CGRect(origin: .zero, size: screen.size))
            XCTAssertNil(selectedWindow)
        }
    }
    func testDesktopDragStillSelectsRectangleAndCommandClickDoesNotSelectWholeScreen() throws {
        var selected: CGRect?, completions = 0, toggled = 0
        let view = FrozenSelectionView(frame: CGRect(x: 0, y: 0, width: 200, height: 120), image: try image(), screenFrame: CGRect(x: 500, y: 0, width: 200, height: 120), candidates: [], smartSelectionEnabled: false, fullScreen: {}, previousArea: {}, toggleWindow: { _ in toggled += 1 }) { selected = $0; completions += 1; XCTAssertNil($1) }
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 20, y: 20), flags: .command))
        XCTAssertTrue(view.selection.isEmpty)
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 20, y: 20), flags: .command))
        XCTAssertEqual(completions, 0); XCTAssertEqual(toggled, 0)
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 20, y: 20)))
        view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 80, y: 70)))
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 80, y: 70)))
        XCTAssertEqual(selected, CGRect(x: 20, y: 20, width: 60, height: 50))
        XCTAssertEqual(completions, 1)
    }
    func testWindowAndDesktopFallbackSwitchWithoutStaleRectAndExitClearsHighlight() throws {
        let window = FrozenWindowCandidate(id: 7, frame: CGRect(x: 10, y: 10, width: 60, height: 50))
        let view = FrozenSelectionView(frame: CGRect(x: 0, y: 0, width: 200, height: 120), image: try image(), screenFrame: CGRect(x: 0, y: 0, width: 200, height: 120), candidates: [window], smartSelectionEnabled: false, fullScreen: {}, previousArea: {}) { _, _ in }
        view.refreshHover(at: CGPoint(x: 30, y: 30)); XCTAssertEqual(view.selection, window.frame)
        view.refreshHover(at: CGPoint(x: 100, y: 80)); XCTAssertEqual(view.selection, view.bounds)
        view.refreshHover(at: CGPoint(x: 30, y: 30)); XCTAssertEqual(view.selection, window.frame)
        view.mouseExited(with: try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: CGPoint(x: 201, y: 121), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        XCTAssertTrue(view.selection.isEmpty)
    }
}
