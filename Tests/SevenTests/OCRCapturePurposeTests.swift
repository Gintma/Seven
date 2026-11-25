import AppKit
import XCTest
@testable import Seven

@MainActor final class OCRCapturePurposeTests: XCTestCase {
    func testTextPurposesExposeOnlyRestoreAndCancelAndKeepIndependentPreviousRegions() {
        for purpose in [FrozenCapturePurpose.ocr, .translation] {
            XCTAssertTrue(purpose.permits(.cancel)); XCTAssertTrue(purpose.permits(.previousArea))
            XCTAssertFalse(purpose.permits(.copyColor)); XCTAssertFalse(purpose.permits(.fullScreen))
        }
        XCTAssertNotEqual(FrozenCapturePurpose.ocr.previousAreaKey, FrozenCapturePurpose.translation.previousAreaKey)
        XCTAssertNotEqual(FrozenCapturePurpose.ocr.previousAreaKey, FrozenCapturePurpose.screenshot.previousAreaKey)
        XCTAssertNotEqual(FrozenCapturePurpose.ocr.smartSelectionKey, FrozenCapturePurpose.translation.smartSelectionKey)
    }
    func testOCRViewDoesNotExposeScreenshotGuidesColorFullScreenOrMultiWindowActions() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        var restored = 0, fullScreen = 0, colorWrites = 0, multi = 0
        let view = FrozenSelectionView(frame: CGRect(x: 0, y: 0, width: 100, height: 80), image: try XCTUnwrap(bitmap.cgImage), screenFrame: CGRect(x: 0, y: 0, width: 100, height: 80), candidates: [], smartSelectionEnabled: false, purpose: .ocr,
            fullScreen: { fullScreen += 1 }, previousArea: { restored += 1 }, toggleWindow: { _ in multi += 1 }, finishWindows: { multi += 1 }, writeColor: { _ in colorWrites += 1; return true }, complete: { _, _ in })
        for code: UInt16 in [3, 8, 15] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            view.keyDown(with: event)
        }
        XCTAssertEqual(restored, 1); XCTAssertEqual(fullScreen, 0); XCTAssertEqual(colorWrites, 0)
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
        let up = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
        view.flagsChanged(with: down); view.flagsChanged(with: up)
        XCTAssertEqual(multi, 0)
    }
}

extension OCRCapturePurposeTests {
    func testDirectScrollCaptureSelectsWindowRectangleWithoutIndependentWindowComposition() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let candidate = FrozenWindowCandidate(id: 1, frame: CGRect(x: 10, y: 10, width: 60, height: 50))
        var rect: CGRect?, selectedWindow: FrozenWindowCandidate?, toggles = 0
        let view = FrozenSelectionView(frame: CGRect(x: 0, y: 0, width: 100, height: 80), image: try XCTUnwrap(bitmap.cgImage), screenFrame: CGRect(x: 0, y: 0, width: 100, height: 80), candidates: [candidate], smartSelectionEnabled: false, purpose: .scroll,
            fullScreen: {}, previousArea: {}, toggleWindow: { _ in toggles += 1 }, finishWindows: { toggles += 1 }, complete: { rect = $0; selectedWindow = $1 })
        let point = CGPoint(x: 30, y: 30)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: down); view.mouseUp(with: up)
        XCTAssertEqual(rect, candidate.frame)
        XCTAssertNil(selectedWindow, "长截图必须使用可滚动的屏幕矩形，不合成独立窗口图片")
        XCTAssertEqual(toggles, 0)
        XCTAssertFalse(FrozenCapturePurpose.scroll.permits(.copyColor))
        XCTAssertNotEqual(FrozenCapturePurpose.scroll.previousAreaKey, FrozenCapturePurpose.ocr.previousAreaKey)
    }
}

extension OCRCapturePurposeTests {
    func testAllSmartSelectionSwitchCombinationsAreIndependentAndScrollUsesScreenshotChoice() throws {
        let suite = "SmartCapturePurpose.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        for mask in 0..<8 {
            let screenshot = mask & 1 != 0, ocr = mask & 2 != 0, translation = mask & 4 != 0
            defaults.set(screenshot, forKey: ScreenshotToolPreferences.smartSelectionKey)
            defaults.set(ocr, forKey: FrozenCapturePurpose.ocr.smartSelectionKey)
            defaults.set(translation, forKey: FrozenCapturePurpose.translation.smartSelectionKey)
            XCTAssertEqual(FrozenCapturePurpose.screenshot.smartSelectionEnabled(in: defaults, accessibilityGranted: true), screenshot)
            XCTAssertEqual(FrozenCapturePurpose.scroll.smartSelectionEnabled(in: defaults, accessibilityGranted: true), screenshot)
            XCTAssertEqual(FrozenCapturePurpose.ocr.smartSelectionEnabled(in: defaults, accessibilityGranted: true), ocr)
            XCTAssertEqual(FrozenCapturePurpose.translation.smartSelectionEnabled(in: defaults, accessibilityGranted: true), translation)
            for purpose in [FrozenCapturePurpose.screenshot, .scroll, .ocr, .translation] {
                XCTAssertFalse(purpose.smartSelectionEnabled(in: defaults, accessibilityGranted: false))
            }
        }
    }
}
