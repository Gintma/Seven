import AppKit
import XCTest
@testable import Seven

private actor HeldScreenshotRecognizer: TextRecognizing {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private(set) var returnedWhileCancelled = false
    func recognizeText(in image: CGImage) async throws -> RecognizedOCRText {
        started = true
        await withCheckedContinuation { continuation = $0 }
        returnedWhileCancelled = Task.isCancelled
        return RecognizedOCRText(text: "late result", averageConfidence: 1)
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor final class ScreenshotOCRTests: XCTestCase {
    private func fixture() throws -> NSImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(size: NSSize(width: 2, height: 2)); image.addRepresentation(bitmap)
        return image
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    func testDisposingOCRWindowCancelsTaskAndIgnoresLateMockResult() async throws {
        _ = NSApplication.shared
        let recognizer = HeldScreenshotRecognizer()
        let controller = ScreenshotOCRWindowController(image: try fixture(), recognizer: recognizer)
        defer { controller.close() }
        for _ in 0..<100 where !(await recognizer.started) { try await Task.sleep(for: .milliseconds(5)) }
        let started = await recognizer.started
        XCTAssertTrue(started)
        controller.dispose()
        await recognizer.release()
        for _ in 0..<100 where !(await recognizer.returnedWhileCancelled) { try await Task.sleep(for: .milliseconds(5)) }
        let cancelled = await recognizer.returnedWhileCancelled
        XCTAssertTrue(cancelled)
        let root = try XCTUnwrap(controller.window?.contentView)
        XCTAssertEqual(descendants(root).compactMap { $0 as? NSTextView }.first?.string, "")
    }

    func testAlreadyCancelledRecognitionReturnsCancellationWithoutStartingWork() async throws {
        let image = try fixture()
        var rect = CGRect(origin: .zero, size: image.size)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let task = Task { try await ScreenshotImageTextRecognizer().recognizeText(in: cg) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("已取消任务不应开始二维码或文字识别")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

extension ScreenshotOCRTests {
    func testHiddenLargeOCRReleasesOriginalAndRestoresSameImageAndEdits() async throws {
        _ = NSApplication.shared
        weak var original: NSImage?
        var expectedPixel: [UInt8] = []
        let recognizer = HeldScreenshotRecognizer()
        let controller = try autoreleasepool {
            let size = NSSize(width: 2100, height: 1800)
            let context = try XCTUnwrap(CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
            let raster = try XCTUnwrap(context.makeImage())
            expectedPixel = Array((try XCTUnwrap(raster.dataProvider?.data) as Data).prefix(4))
            let image = NSImage(cgImage: raster, size: size)
            original = image
            return ScreenshotOCRWindowController(image: image, result: .init(text: "before", averageConfidence: 1),
                                                 recognizer: recognizer, defaults: nil, supportedLanguages: ["en"])
        }
        defer { controller.dispose() }
        controller.showWindow(nil)
        controller.replaceText("edited", action: "编辑")
        controller.close()
        for _ in 0..<60 where original != nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(original, "已收起的可压缩原图不应继续持有展开的像素")
        controller.showWindow(nil)
        controller.toggleOriginal()
        let restoredImage = try XCTUnwrap(controller.imagePreview?.image)
        let restored = try XCTUnwrap(restoredImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(restored.width, 2100)
        XCTAssertEqual(restored.height, 1800)
        XCTAssertEqual(restored.colorSpace?.name, CGColorSpace.displayP3)
        let restoredPixel = try XCTUnwrap(restored.dataProvider?.data) as Data
        XCTAssertEqual(Array(restoredPixel.prefix(4)), expectedPixel)
        XCTAssertEqual(controller.textView.string, "edited")
        controller.textView.undoManager?.undo()
        XCTAssertEqual(controller.textView.string, "before")
        controller.toggleOriginal()
        controller.close()
        controller.showWindow(nil)
        XCTAssertTrue(controller.imagePreview?.image === restoredImage, "快速重开保留已解码的图片")
        controller.close()
        for _ in 0..<60 where controller.imagePreview?.image != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(controller.imagePreview?.image)
        controller.showWindow(nil)
        XCTAssertNil(controller.imagePreview?.image, "文字栏重开不需要解码原图")
        controller.selectLanguage("en")
        for _ in 0..<100 where !(await recognizer.started) { try await Task.sleep(for: .milliseconds(5)) }
        let started = await recognizer.started
        XCTAssertTrue(started)
        await recognizer.release()
        for _ in 0..<100 where controller.isRecognizing { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(controller.textView.string, "late result")
    }

    func testHidingWhileRecognizingRetainsResultWithoutShowingWindowAndCanReopen() async throws {
        let recognizer = HeldScreenshotRecognizer()
        let controller = ScreenshotOCRWindowController(image: try fixture(), recognizer: recognizer, defaults: nil)
        defer { controller.dispose() }
        controller.showWindow(nil)
        for _ in 0..<100 where !(await recognizer.started) { try await Task.sleep(for: .milliseconds(5)) }
        controller.close()
        XCTAssertFalse(controller.window?.isVisible == true)
        await recognizer.release()
        for _ in 0..<100 where controller.isRecognizing { try await Task.sleep(for: .milliseconds(5)) }
        let wasCancelled = await recognizer.returnedWhileCancelled
        XCTAssertFalse(wasCancelled)
        XCTAssertEqual(controller.textView.string, "late result")
        XCTAssertFalse(controller.window?.isVisible == true, "隐藏时完成识别不能自己弹出")
        controller.showWindow(nil)
        XCTAssertTrue(controller.window?.isVisible == true)
        XCTAssertEqual(controller.textView.string, "late result")
    }
}
