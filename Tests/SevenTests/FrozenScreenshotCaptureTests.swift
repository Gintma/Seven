import AppKit
import XCTest
@testable import Seven

@MainActor
private final class FrozenCaptureFixture: FrozenScreenshotCapturing {
    var calls = 0
    var frames: [FrozenScreenshotFrame] = []
    var fails = false
    func freezeScreens() async throws -> [FrozenScreenshotFrame] {
        calls += 1
        if fails { throw CocoaError(.featureUnsupported) }
        return frames
    }
}

@MainActor
private final class SuspendedFrozenCapture: FrozenScreenshotCapturing {
    var onRequest: ((Int) -> Void)?
    var onReturn: ((Int, Bool) -> Void)?
    private var requestCount = 0
    private var pending: [Int: CheckedContinuation<[FrozenScreenshotFrame], Never>] = [:]

    func freezeScreens() async throws -> [FrozenScreenshotFrame] {
        requestCount += 1
        let request = requestCount
        let frames = await withCheckedContinuation { continuation in
            pending[request] = continuation
            onRequest?(request)
        }
        onReturn?(request, Task.isCancelled)
        return frames
    }

    func complete(_ request: Int, with frames: [FrozenScreenshotFrame]) {
        pending.removeValue(forKey: request)?.resume(returning: frames)
    }

    func finishOutstandingRequests() {
        for request in Array(pending.keys) { complete(request, with: []) }
    }
}

@MainActor
final class FrozenScreenshotCaptureTests: XCTestCase {
    func testSelectionResizeTruncatesClampsAndKeepsOriginalOppositeAnchor() {
        let original = CGRect(x: 20, y: 30, width: 40, height: 50)
        let bounds = CGSize(width: 100, height: 100)
        XCTAssertEqual(FrozenSelectionGeometry.resized(original, handle: .topRight, to: CGPoint(x: 105.9, y: 93.9), within: bounds), CGRect(x: 20, y: 30, width: 80, height: 63))
        XCTAssertEqual(FrozenSelectionGeometry.resized(original, handle: .bottomLeft, to: CGPoint(x: -4.5, y: -2.8), within: bounds), CGRect(x: 0, y: 0, width: 60, height: 80))
        XCTAssertEqual(FrozenSelectionGeometry.resized(original, handle: .left, to: CGPoint(x: 85.8, y: 40), within: bounds), CGRect(x: 60, y: 30, width: 25, height: 50))
        // 同一手势继续越过对边时仍以mouseDown的original为基准，不把上一规范化rect累加。
        XCTAssertEqual(FrozenSelectionGeometry.resized(original, handle: .left, to: CGPoint(x: 90, y: 40), within: bounds), CGRect(x: 60, y: 30, width: 30, height: 50))
    }

    func testSelectionMovePreservesSizeAndWritesIntegerMouseAnchor() {
        let original = CGRect(x: 20, y: 30, width: 40, height: 50)
        let bounds = CGSize(width: 100, height: 100)
        let point = CGPoint(x: 45.9, y: 50.9)
        let first = FrozenSelectionGeometry.moved(original, from: CGPoint(x: 40, y: 50), to: point, within: bounds)
        XCTAssertEqual(first, CGRect(x: 25, y: 30, width: 40, height: 50))
        XCTAssertEqual(FrozenSelectionGeometry.movingAnchor(for: point), CGPoint(x: 45, y: 50))
        XCTAssertEqual(FrozenSelectionGeometry.moved(first, from: CGPoint(x: 45, y: 50), to: CGPoint(x: 200, y: 200), within: bounds), CGRect(x: 60, y: 50, width: 40, height: 50))
        XCTAssertEqual(FrozenSelectionGeometry.moved(original, from: .zero, to: CGPoint(x: -100, y: -100), within: bounds), CGRect(x: 0, y: 0, width: 40, height: 50))
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        let bytes = [UInt8](repeating: 255, count: width * height * 4)
        let data = Data(bytes) as CFData
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    func testFrozenSelectionUsesOriginalPixelsAndRetainsLogicalSize() throws {
        let frame = FrozenScreenshotFrame(screenFrame: CGRect(x: -200, y: 100, width: 100, height: 80),
                                          image: try image(width: 200, height: 160))
        let cropped = try XCTUnwrap(frame.croppedImage(in: CGRect(x: 10, y: 20, width: 30, height: 40)))
        XCTAssertEqual(cropped.size, CGSize(width: 30, height: 40))
        let result = try XCTUnwrap(cropped.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(result.width, 60)
        XCTAssertEqual(result.height, 80)
    }
    func testFullScreenHandsFrozenContextToEditorWithoutKeepingItInCoordinator() async throws {
        let capture = FrozenCaptureFixture()
        let pixels = try image(width: 200, height: 160)
        capture.frames = [FrozenScreenshotFrame(screenFrame: CGRect(x: -200, y: 100, width: 100, height: 80), image: pixels)]
        let coordinator = FrozenScreenshotCaptureCoordinator(capture: capture, hasPermission: { true }, defaults: try XCTUnwrap(isolatedDefaults()))
        var output: NSImage?
        var handedOffContext: FrozenSelectionContext?
        let completed = expectation(description: "全屏截图已交付")
        coordinator.captureFullScreen {
            if case .success(let image) = $0 { output = image }
            handedOffContext = coordinator.lastSelectionContext
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(output?.size, CGSize(width: 100, height: 80))
        XCTAssertNil(coordinator.lastSelectionContext, "交给编辑器后，协调器不应继续持有整屏图")
        let context = try XCTUnwrap(handedOffContext)
        XCTAssertEqual(context.screenFrame, capture.frames[0].screenFrame)
        XCTAssertEqual(context.localSelection, CGRect(x: 0, y: 0, width: 100, height: 80))
        XCTAssertEqual(context.image.width, 200)
        let recrop = try XCTUnwrap(context.croppedImage(in: CGRect(x: 10, y: 20, width: 30, height: 40)))
        XCTAssertEqual(recrop.size, CGSize(width: 30, height: 40))
        XCTAssertEqual(capture.calls, 1, "改变选区仍从原冻结图裁剪，不重新访问屏幕")
    }

    func testOCRPreviousAreaDoesNotKeepFullScreenPixels() async throws {
        _ = NSApplication.shared
        let defaults = try XCTUnwrap(isolatedDefaults())
        defaults.set(false, forKey: FrozenCapturePurpose.ocr.smartSelectionKey)
        let region = CGRect(x: 10, y: 20, width: 30, height: 15)
        defaults.set(NSStringFromRect(region), forKey: FrozenCapturePurpose.ocr.previousAreaKey)
        let capture = FrozenCaptureFixture()
        let coordinator = FrozenScreenshotCaptureCoordinator(
            capture: capture, hasPermission: { true }, defaults: defaults, windowCandidatesProvider: { [] }
        )
        defer { coordinator.cancel() }
        weak var source: CGImage?
        var result: NSImage?
        var handedOffContext: FrozenSelectionContext?
        try autoreleasepool {
            let frozenImage = try image(width: 200, height: 160)
            source = frozenImage
            capture.frames = [.init(screenFrame: CGRect(x: 0, y: 0, width: 100, height: 80), image: frozenImage)]
        }
        coordinator.start(purpose: .ocr) { captureResult in
            if case .success(let image) = captureResult { result = image }
            handedOffContext = coordinator.lastSelectionContext
        }
        await waitForSelectionPanel()
        try autoreleasepool {
            let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is FrozenSelectionView })
            let view = try XCTUnwrap(panel.contentView as? FrozenSelectionView)
            view.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "r",
                charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15)))
            capture.frames.removeAll()
        }
        XCTAssertNil(handedOffContext)
        XCTAssertNil(coordinator.lastSelectionContext)
        XCTAssertNil(source, "OCR 结果仍在内存时，原冻结画面应该已经释放")
        XCTAssertEqual(result?.size, region.size)
        let crop = try XCTUnwrap(result?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(crop.width, 60)
        XCTAssertEqual(crop.height, 30)
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: crop).colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01)
    }
    private func waitForSelectionPanel() async {
        for _ in 0..<100 {
            let visible = autoreleasepool {
                NSApp.windows.contains { $0.isVisible && $0.contentView is FrozenSelectionView }
            }
            if visible { return }
            await Task.yield()
        }
    }

    func testCopyColorLeavesCaptureOnlyAfterSuccessfulClipboardWrite() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        for succeeds in [false, true] {
            var copied: String?, completions = 0
            let view = FrozenSelectionView(frame: CGRect(x: 0, y: 0, width: 200, height: 160), image: try image(width: 200, height: 160), screenFrame: CGRect(x: 0, y: 0, width: 200, height: 160), candidates: [], fullScreen: {}, previousArea: {}, writeColor: { copied = $0; return succeeds }) { rect, candidate in
                XCTAssertNil(rect); XCTAssertNil(candidate); completions += 1
            }
            view.refreshHover(at: CGPoint(x: 60, y: 60))
            view.keyDown(with: event)
            XCTAssertEqual(copied, "FFFFFF")
            XCTAssertEqual(completions, succeeds ? 1 : 0)
        }
    }

    func testColorReadoutPreservesHexRounding() {
        XCTAssertEqual(FrozenMagnifierLabels.hex(red: 0, green: 0, blue: 0), "000000")
        XCTAssertEqual(FrozenMagnifierLabels.hex(red: 1, green: 1, blue: 1), "FFFFFF")
        XCTAssertEqual(FrozenMagnifierLabels.hex(red: 0, green: 0, blue: 128.0 / 255), "000080")
        XCTAssertEqual(FrozenMagnifierLabels.hex(red: 0.5, green: 0.5, blue: 0.5), "808080")
    }

    func testMagnifierReadoutUsesFrozenSourceAndTopOriginCoordinates() throws {
        let magnifier = FrozenMagnifierView()
        magnifier.update(image: try image(width: 200, height: 160), point: CGPoint(x: 20, y: 30), screenSize: CGSize(width: 100, height: 80))
        XCTAssertFalse(magnifier.isHidden)
        XCTAssertEqual(magnifier.coordinateText, "20,50")
        XCTAssertEqual(magnifier.hexColor, "FFFFFF")
        // Both original labels and pixel crop use current-screen local coordinates, not global desktop coordinates.
        XCTAssertEqual(FrozenMagnifierLabels.coordinate(CGPoint(x: 20.4, y: 30.4), screenHeight: 80), "20,50")
    }

    func testMagnifierReadsExactPhysicalPixelAtAllEdgesAndCenterAtOneAndTwoX() throws {
        for scale in [1, 2] {
            let width = 100 * scale, height = 80 * scale
            var bytes = [UInt8]()
            for y in 0..<height { for x in 0..<width { bytes += [UInt8(x), UInt8(y), 0, 255] } }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
            let source = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let magnifier = FrozenMagnifierView()
            for (x, y) in [(0, height / 2), (width - 1, height / 2), (width / 2, 0), (width / 2, height - 1), (width / 2, height / 2)] {
                // y是AppKit底部起算的物理像素行；原图数据为顶部起算。
                magnifier.update(image: source, point: CGPoint(x: CGFloat(x) / CGFloat(scale), y: CGFloat(y) / CGFloat(scale)), screenSize: CGSize(width: 100, height: 80))
                let color = try XCTUnwrap(magnifier.sampledColor?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(Int((color.redComponent * 255).rounded()), x, "\(scale)x x=\(x), y=\(y)")
                XCTAssertEqual(Int((color.greenComponent * 255).rounded()), height - 1 - y, "\(scale)x x=\(x), y=\(y)")
                let expected = FrozenMagnifierLabels.hex(red: CGFloat(x) / 255, green: CGFloat(height - 1 - y) / 255, blue: 0)
                XCTAssertEqual(magnifier.hexColor, expected)
            }
        }
    }

    func testFrozenSelectionClipsToScreenAndRejectsEmptyRectangle() throws {
        let frame = FrozenScreenshotFrame(screenFrame: CGRect(x: 0, y: 0, width: 100, height: 80),
                                          image: try image(width: 200, height: 160))
        XCTAssertNil(frame.croppedImage(in: .zero))
        XCTAssertNil(frame.croppedImage(in: CGRect(x: 200, y: 0, width: 10, height: 10)))
        let cropped = try XCTUnwrap(frame.croppedImage(in: CGRect(x: -5, y: -5, width: 20, height: 20)))
        XCTAssertEqual(cropped.size, CGSize(width: 15, height: 15))
    }
    func testFrozenCropFlipsAppKitYToTopOriginPixelRows() throws {
        let bytes: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255,
                              0, 0, 255, 255, 0, 0, 255, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let frame = FrozenScreenshotFrame(screenFrame: CGRect(x: 0, y: 0, width: 2, height: 2), image: image)
        let top = try XCTUnwrap(frame.croppedImage(in: CGRect(x: 0, y: 1, width: 2, height: 1)))
        let topImage = try XCTUnwrap(top.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let data = try XCTUnwrap(topImage.dataProvider?.data) as Data
        XCTAssertEqual(Array(data.prefix(4)), [255, 0, 0, 255])
    }
    func testWindowHoverRetainsAppWindowOrderAndExcludesFullScreenDock() {
        func item(_ id: Int, _ layer: Int, _ y: Int) -> [String: Any] {
            [kCGWindowNumber as String: NSNumber(value: id), kCGWindowLayer as String: layer,
             kCGWindowBounds as String: ["X": NSNumber(value: -100), "Y": NSNumber(value: y),
                                        "Width": NSNumber(value: 100), "Height": NSNumber(value: 50)]]
        }
        let candidates = FrozenWindowCandidate.candidates(from: [item(1, -1, 10), item(2, 0, 20), item(3, 3, 30), item(4, Int(CGWindowLevelForKey(.dockWindow)), 0), item(5, 1000, 40)], primaryScreenTop: 800)
        XCTAssertEqual(candidates.map(\.id), [2, 3])
        XCTAssertEqual(candidates[0].frame, CGRect(x: -100, y: 730, width: 100, height: 50))
    }
    func testPreviousAreaMovesOriginWithoutChangingSize() {
        XCTAssertEqual(FrozenScreenshotCaptureCoordinator.previousArea(CGRect(x: 80, y: 65, width: 30, height: 25), fitting: CGSize(width: 100, height: 80)), CGRect(x: 70, y: 55, width: 30, height: 25))
    }
    func testPreviousAreaIsPersistedOnlyByExplicitSuccessfulExport() throws {
        let defaults = try XCTUnwrap(isolatedDefaults())
        let coordinator = FrozenScreenshotCaptureCoordinator(capture: FrozenCaptureFixture(), hasPermission: { true }, defaults: defaults)
        XCTAssertFalse(coordinator.hasPreviousArea)
        coordinator.rememberArea(CGRect(x: -180, y: 120, width: 30, height: 40), on: CGRect(x: -200, y: 100, width: 100, height: 80))
        XCTAssertEqual(NSRectFromString(try XCTUnwrap(defaults.string(forKey: "screenshotPreviousArea.v1"))), CGRect(x: 20, y: 20, width: 30, height: 40))
        XCTAssertTrue(coordinator.hasPreviousArea)
    }
    func testPermissionDeniedNeverCallsCaptureOrShowsPanel() {
        let capture = FrozenCaptureFixture()
        let coordinator = FrozenScreenshotCaptureCoordinator(capture: capture, hasPermission: { false })
        var result: ScreenshotTranslationError?
        coordinator.start { if case .failure(let error) = $0 { result = error } }
        XCTAssertEqual(result, .permissionDenied)
        XCTAssertEqual(capture.calls, 0)
    }
    func testCaptureFailureFinishesOnceAndCancelDoesNotRepeatCompletion() async {
        let capture = FrozenCaptureFixture(); capture.fails = true
        let coordinator = FrozenScreenshotCaptureCoordinator(capture: capture, hasPermission: { true })
        var calls = 0
        let failed = expectation(description: "取图错误已交付")
        coordinator.start {
            calls += 1
            if case .failure(let error) = $0 { XCTAssertEqual(error, .captureFailed) }
            else { XCTFail("捕获失败不能产出图片") }
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertFalse(coordinator.isCapturing)
        coordinator.cancel()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(capture.calls, 1)
    }
    func testCancelDuringFreezeDiscardsLateImage() async throws {
        let capture = SuspendedFrozenCapture()
        let coordinator = FrozenScreenshotCaptureCoordinator(capture: capture, hasPermission: { true })
        defer { coordinator.cancel(); capture.finishOutstandingRequests() }
        let started = expectation(description: "取图已开始")
        let returned = expectation(description: "取消后的后端已返回")
        capture.onRequest = { _ in started.fulfill() }
        capture.onReturn = { _, cancelled in
            XCTAssertTrue(cancelled)
            returned.fulfill()
        }
        var errors: [ScreenshotTranslationError] = []
        coordinator.captureFullScreen { result in
            if case .failure(let error) = result { errors.append(error) }
            else { XCTFail("取消后不得交付图片") }
        }
        XCTAssertTrue(coordinator.isCapturing)
        await fulfillment(of: [started], timeout: 2)
        coordinator.cancel()
        XCTAssertFalse(coordinator.isCapturing)
        XCTAssertEqual(errors, [.cancelled])
        capture.complete(1, with: [.init(screenFrame: CGRect(x: 0, y: 0, width: 30, height: 20),
                                        image: try image(width: 60, height: 40))])
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(errors, [.cancelled])
        XCTAssertNil(coordinator.lastSelectionContext)
        XCTAssertNil(coordinator.lastCaptureRect)
    }

    func testSecondCaptureOwnsResultWhenFirstBackendReturnsLate() async throws {
        let capture = SuspendedFrozenCapture()
        let coordinator = FrozenScreenshotCaptureCoordinator(capture: capture, hasPermission: { true })
        defer { coordinator.cancel(); capture.finishOutstandingRequests() }
        let first = expectation(description: "首次取图已开始")
        let second = expectation(description: "第二次取图已开始")
        let delivered = expectation(description: "新会话已交付")
        let returned = expectation(description: "旧后端晚于新会话返回")
        capture.onRequest = { request in
            (request == 1 ? first : second).fulfill()
        }
        capture.onReturn = { request, cancelled in
            if request == 1 {
                XCTAssertTrue(cancelled)
                returned.fulfill()
            }
        }
        var errors: [ScreenshotTranslationError] = []
        coordinator.captureFullScreen { result in
            if case .failure(let error) = result { errors.append(error) }
            else { XCTFail("旧会话不得交付图片") }
        }
        await fulfillment(of: [first], timeout: 2)
        let currentRect = CGRect(x: -50, y: 10, width: 40, height: 30)
        coordinator.captureFullScreen { result in
            if case .success(let image) = result { XCTAssertEqual(image.size, currentRect.size) }
            else { XCTFail("新会话应成功交付") }
            delivered.fulfill()
        }
        await fulfillment(of: [second], timeout: 2)
        XCTAssertTrue(coordinator.isCapturing)
        XCTAssertEqual(errors, [.cancelled])
        capture.complete(2, with: [.init(screenFrame: currentRect, image: try image(width: 80, height: 60))])
        await fulfillment(of: [delivered], timeout: 2)
        capture.complete(1, with: [.init(screenFrame: CGRect(x: 0, y: 0, width: 30, height: 20),
                                        image: try image(width: 60, height: 40))])
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(errors, [.cancelled])
        XCTAssertEqual(coordinator.lastCaptureRect, currentRect)
        XCTAssertFalse(coordinator.isCapturing)
    }

    func testCommandClicksToggleWindowsAndOnlyReleaseFinishesSelection() throws {
        _ = NSApplication.shared
        let first = FrozenWindowCandidate(id: 1, frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        let second = FrozenWindowCandidate(id: 2, frame: CGRect(x: 50, y: 10, width: 20, height: 20))
        var toggles: [CGWindowID] = [], completions = 0, releases = 0
        let view = FrozenSelectionView(frame: CGRect(x: 0, y: 0, width: 100, height: 80), image: try image(width: 200, height: 160), screenFrame: CGRect(x: 0, y: 0, width: 100, height: 80), candidates: [first, second], fullScreen: {}, previousArea: {}, toggleWindow: { toggles.append($0.id) }, finishWindows: { releases += 1 }) { _, _ in completions += 1 }
        func click(_ point: CGPoint) throws {
            view.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            view.mouseUp(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)))
        }
        try click(CGPoint(x: 15, y: 15)); try click(CGPoint(x: 55, y: 15)); try click(CGPoint(x: 15, y: 15))
        XCTAssertEqual(toggles, [1, 2, 1]); XCTAssertEqual(completions, 0); XCTAssertEqual(releases, 0)
        view.flagsChanged(with: try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)))
        XCTAssertEqual(releases, 1)
    }

    func testMultiWindowToggleRetainsFrontOrderAndRejectsOtherScreen() {
        let front = FrozenWindowCandidate(id: 1, frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        let rear = FrozenWindowCandidate(id: 2, frame: CGRect(x: 20, y: 20, width: 20, height: 20))
        let other = FrozenWindowCandidate(id: 3, frame: CGRect(x: 110, y: 10, width: 20, height: 20))
        let screen = CGRect(x: 0, y: 0, width: 100, height: 100)
        var selection = FrozenMultiWindowSelection()
        selection.toggle(rear, on: screen); selection.toggle(front, on: screen)
        selection.toggle(other, on: screen.offsetBy(dx: 100, dy: 0))
        XCTAssertEqual(selection.ordered(in: [front, rear, other]).map(\.id), [1, 2])
        selection.toggle(front, on: screen)
        XCTAssertEqual(selection.ids, [2])
        selection.toggle(rear, on: screen)
        XCTAssertNil(selection.screenFrame)
    }

    func testShiftSquareKeepsAnchorAllDirectionsAndScreenBoundary() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80), anchor = CGPoint(x: 40, y: 30)
        for point in [CGPoint(x: 70, y: 50), CGPoint(x: 10, y: 50), CGPoint(x: 10, y: 5), CGPoint(x: 70, y: 5), CGPoint(x: 140, y: 90)] {
            let rect = FrozenSquareSelection.rect(from: anchor, to: point, within: bounds, square: true)
            XCTAssertEqual(rect.width, rect.height)
            XCTAssertTrue(bounds.contains(rect))
            XCTAssertTrue(rect.minX == anchor.x || rect.maxX == anchor.x)
            XCTAssertTrue(rect.minY == anchor.y || rect.maxY == anchor.y)
        }
        XCTAssertEqual(FrozenSquareSelection.rect(from: anchor, to: CGPoint(x: 70, y: 50), within: bounds, square: false), CGRect(x: 40, y: 30, width: 30, height: 20))
    }

    private func solid(_ color: NSColor, size: NSSize) throws -> NSImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide { bitmap.setColor(color, atX: x, y: y) } }
        let image = NSImage(size: size); image.addRepresentation(bitmap); return image
    }

    func testMultiWindowCompositionPreservesOrderTransparentGapsAndRetinaPixels() throws {
        let front = FrozenWindowCandidate(id: 1, frame: CGRect(x: -90, y: 30, width: 20, height: 20))
        let rear = FrozenWindowCandidate(id: 2, frame: CGRect(x: -80, y: 20, width: 20, height: 20))
        let output = try XCTUnwrap(FrozenMultiWindowComposition.image(candidates: [front, rear], images: [solid(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), size: front.frame.size), solid(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), size: rear.frame.size)], screenFrame: CGRect(x: -100, y: 0, width: 100, height: 80)))
        XCTAssertEqual(output.size, NSSize(width: 30, height: 30))
        let cg = try XCTUnwrap(output.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, 60); XCTAssertEqual(cg.height, 60)
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let overlap = try XCTUnwrap(bitmap.colorAt(x: 30, y: 30)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(overlap.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(overlap.blueComponent, 0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 5, y: 55)).alphaComponent, 0, accuracy: 0.01, "未选窗口和桌面不应填入union空隙")
    }

    func testMultiWindowCompositionPreservesContentInEachWindow() throws {
        let front = FrozenWindowCandidate(id: 1, frame: CGRect(x: 220, y: 220, width: 440, height: 340))
        let rear = FrozenWindowCandidate(id: 2, frame: CGRect(x: 500, y: 330, width: 460, height: 320))
        let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
        let blue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
        let images = try [solid(red, size: front.frame.size), solid(blue, size: rear.frame.size)]
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let context = try XCTUnwrap(FrozenMultiWindowComposition.selectionContext(
            candidates: [front, rear], images: images, screenFrame: screen))
        let output = try XCTUnwrap(context.croppedImage(in: context.localSelection))
        let bitmap = try XCTUnwrap(ScreenshotSaving.bitmap(output))
        let scale = CGFloat(bitmap.pixelsWide) / output.size.width
        for (window, sample) in [(front, red), (rear, blue)] {
            let x = (window.id == front.id ? window.frame.minX + 20 : window.frame.maxX - 20) - context.localSelection.minX
            let y = context.localSelection.maxY - window.frame.midY
            let pixel = try XCTUnwrap(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(pixel.redComponent, sample.redComponent, accuracy: 0.03)
            XCTAssertEqual(pixel.blueComponent, sample.blueComponent, accuracy: 0.03)
            XCTAssertEqual(pixel.alphaComponent, 1, accuracy: 0.01)
        }
    }

    func testMultiWindowCaptureFailureDoesNotDeliverPartialComposite() async throws {
        let fixture = IndependentWindowFixture()
        fixture.image = try solid(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), size: NSSize(width: 20, height: 20))
        fixture.failedID = 2
        let candidates = [FrozenWindowCandidate(id: 1, frame: CGRect(x: 0, y: 0, width: 20, height: 20)), FrozenWindowCandidate(id: 2, frame: CGRect(x: 30, y: 0, width: 20, height: 20))]
        let coordinator = FrozenScreenshotCaptureCoordinator(capture: FrozenCaptureFixture(), hasPermission: { true }, defaults: try XCTUnwrap(isolatedDefaults()), windowCapture: fixture)
        var completions = 0
        coordinator.captureWindows(candidates, on: CGRect(x: 0, y: 0, width: 100, height: 80)) { result in
            completions += 1
            if case .failure(let error) = result { XCTAssertEqual(error, .captureFailed) }
            else { XCTFail("单个窗口失效时不能交付不完整合成") }
        }
        for _ in 0..<100 where coordinator.isCapturing { await Task.yield() }
        XCTAssertEqual(fixture.ids, [1, 2]); XCTAssertEqual(completions, 1)
        coordinator.cancel(); XCTAssertEqual(completions, 1)
    }

    func testWindowCaptureKeepsFrozenMaskVisibleUntilEditorHandoff() async throws {
        _ = NSApplication.shared
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let candidate = FrozenWindowCandidate(id: 1, frame: CGRect(x: 100, y: 100, width: 300, height: 200))
        let capture = FrozenCaptureFixture()
        capture.frames = [FrozenScreenshotFrame(screenFrame: screen, image: try image(width: 800, height: 600))]
        let backend = IndependentWindowFixture()
        backend.held = true
        backend.image = NSImage(cgImage: try image(width: 300, height: 200), size: candidate.frame.size)
        let defaults = try XCTUnwrap(isolatedDefaults())
        defaults.set(false, forKey: ScreenshotToolPreferences.smartSelectionKey)
        let coordinator = FrozenScreenshotCaptureCoordinator(capture: capture, hasPermission: { true }, defaults: defaults,
            windowCapture: backend, windowCandidatesProvider: { [candidate] })
        defer { coordinator.cancel() }
        var completions = 0
        var maskVisibleAtHandoff = false
        coordinator.start { result in
            completions += 1
            if case .success = result {
                maskVisibleAtHandoff = NSApp.windows.contains { $0.contentView is FrozenSelectionView && $0.isVisible }
            }
        }
        await waitForSelectionPanel()
        let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is FrozenSelectionView })
        let view = try XCTUnwrap(panel.contentView as? FrozenSelectionView)
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 200, y: 200)))
        view.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 200, y: 200)))
        XCTAssertTrue(panel.isVisible, "选择窗口后不能先露出实时桌面")
        for _ in 0..<100 where backend.continuation == nil { await Task.yield() }
        XCTAssertNotNil(backend.continuation)
        XCTAssertTrue(panel.isVisible, "异步采集窗口期间须保留冻结蒙层")
        view.refreshHover(at: CGPoint(x: 700, y: 500))
        XCTAssertEqual(view.selection, candidate.frame, "等待期间不能把窗口高亮改成另一个选区")
        let fullScreen = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 2,
            windowNumber: panel.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        view.keyDown(with: fullScreen)
        XCTAssertEqual(completions, 0, "等待期间不能被第二次取区抢先完成")
        backend.continuation?.resume(); backend.continuation = nil
        for _ in 0..<100 where coordinator.isCapturing { await Task.yield() }
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(maskVisibleAtHandoff, "先交付编辑层，再关闭冻结蒙层")
        XCTAssertFalse(panel.isVisible)
    }

    func testMultiWindowAsyncCaptureUsesSelectedIDsAndCancellationDiscardsLateImages() async throws {
        let fixture = IndependentWindowFixture()
        fixture.image = try solid(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), size: NSSize(width: 20, height: 20))
        let candidates = [FrozenWindowCandidate(id: 1, frame: CGRect(x: 0, y: 0, width: 20, height: 20)), FrozenWindowCandidate(id: 2, frame: CGRect(x: 30, y: 0, width: 20, height: 20))]
        let coordinator = FrozenScreenshotCaptureCoordinator(capture: FrozenCaptureFixture(), hasPermission: { true }, defaults: try XCTUnwrap(isolatedDefaults()), windowCapture: fixture)
        var output: NSImage?
        var handedOffContext: FrozenSelectionContext?
        coordinator.captureWindows(candidates, on: CGRect(x: 0, y: 0, width: 100, height: 80)) {
            if case .success(let image) = $0 { output = image }
            handedOffContext = coordinator.lastSelectionContext
        }
        for _ in 0..<100 where coordinator.isCapturing { await Task.yield() }
        XCTAssertEqual(fixture.ids, [1, 2]); XCTAssertEqual(output?.size, NSSize(width: 50, height: 20))
        XCTAssertNil(coordinator.lastSelectionContext)
        let context = try XCTUnwrap(handedOffContext)
        XCTAssertTrue(context.isWindowComposition)
        XCTAssertEqual(context.localSelection, CGRect(x: 0, y: 0, width: 50, height: 20))
        let editor = ScreenshotEditorWindowController(image: try XCTUnwrap(output), context: .selection(context), preferences: ScreenshotToolPreferences())
        defer { editor.close() }
        XCTAssertEqual(editor.window?.frame.size, context.screenFrame.size)
        fixture.held = true
        var completions = 0
        coordinator.captureWindows(candidates, on: CGRect(x: 0, y: 0, width: 100, height: 80)) { result in
            completions += 1
            if case .success = result { XCTFail("取消后旧图不得交付") }
        }
        for _ in 0..<100 where fixture.continuation == nil { await Task.yield() }
        XCTAssertNotNil(fixture.continuation)
        coordinator.cancel()
        fixture.continuation?.resume(); fixture.continuation = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(coordinator.isCapturing)
    }

}


@MainActor private final class IndependentWindowFixture: IndependentWindowCapturing {
    var image = NSImage()
    var ids: [CGWindowID] = []
    var held = false
    var failedID: CGWindowID?
    var continuation: CheckedContinuation<Void, Never>?
    func capture(_ candidate: FrozenWindowCandidate) async throws -> NSImage {
        ids.append(candidate.id)
        if candidate.id == failedID { throw ScreenshotTranslationError.captureFailed }
        if held { await withCheckedContinuation { continuation = $0 } }
        return image
    }
}

extension FrozenScreenshotCaptureTests {
    func testExplicitTranslationWindowCanBeSelectedWithoutAllowingDockOverlays() {
        func item(_ id: Int, layer: Int) -> [String: Any] {
            [kCGWindowNumber as String: NSNumber(value: id), kCGWindowLayer as String: layer,
             kCGWindowBounds as String: ["X": 10, "Y": 10, "Width": 300, "Height": 200]]
        }
        let items = [item(1, layer: Int(NSWindow.Level.statusBar.rawValue)),
                     item(2, layer: Int(CGWindowLevelForKey(.dockWindow))), item(3, layer: 0)]
        let candidates = FrozenWindowCandidate.candidates(from: items, primaryScreenTop: 1000, includingWindowIDs: [1])
        XCTAssertEqual(candidates.map(\.id), [1, 3])
    }

    func testEnlargingWindowCaptureDoesNotExportDesktopPreview() throws {
        let desktop = try image(width: 200, height: 200)
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let window = CGRect(x: 50, y: 50, width: 40, height: 40)
        let captured = try solid(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), size: window.size)
        let selection = try XCTUnwrap(FrozenMultiWindowComposition.selectionContext(
            candidates: [.init(id: 1, frame: window)], images: [captured], screenFrame: bounds, backgroundImage: desktop))
        let enlarged = try XCTUnwrap(selection.croppedImage(in: CGRect(x: 25, y: 25, width: 100, height: 100)))
        let bitmap = try XCTUnwrap(ScreenshotSaving.bitmap(enlarged))
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 1, y: 1)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)).alphaComponent, 0.99)
    }
}
