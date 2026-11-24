import AppKit
import XCTest
@testable import Seven

final class OCRResultLayoutTests: XCTestCase {
    func testThreeModesDoNotChangePunctuation() {
        let text = "中文，保留。\nEnglish, retained."
        XCTAssertEqual(OCRResultLayout.lines.apply(to: text), text)
        XCTAssertEqual(OCRResultLayout.merged.apply(to: text), "中文，保留。English, retained.")
    }
    func testMergeJoinsLatinWithSpacesAndCJKWithoutAddedSpacesAndKeepsHyphen() {
        XCTAssertEqual(OCRResultLayout.merged.apply(to: "hello\nworld\n\nagain"), "hello world again")
        XCTAssertEqual(OCRResultLayout.merged.apply(to: "你好\n世界"), "你好世界")
        XCTAssertEqual(OCRResultLayout.merged.apply(to: "well-\nknown"), "well- known")
    }
    func testPreserveModeDoesNotModifyCodeIndentationOrBlankLines() {
        let code = "func f() {\n    return 1\n}\n\n/path/a-b"
        XCTAssertEqual(OCRResultLayout.lines.apply(to: code), code)
    }
    func testLanguageMenuUsesSupportedLanguagesAndCommonOrderOnly() {
        let ordered = OCRRecognitionLanguages.ordered(["en-US", "ja-JP", "zh-Hans", "fr-FR"], common: ["ja", "de", "zh-Hans", "en"])
        XCTAssertEqual(ordered.common, ["ja-JP", "zh-Hans", "en-US"])
        XCTAssertEqual(ordered.other, ["fr-FR"])
        XCTAssertEqual(OCRRecognitionLanguages.name("ja-JP"), LanguageCatalog.name("ja"))
    }
}

@MainActor final class OCRResultWindowTests: XCTestCase {
    private func image() -> NSImage { NSImage(size: NSSize(width: 80, height: 60), flipped: false) { _ in true } }
    func testLayoutTransformsCurrentEditsAndUndoRestoresOneWholeOperation() throws {
        _ = NSApplication.shared
        let controller = ScreenshotOCRWindowController(result: .init(text: "first\nsecond", averageConfidence: 1), defaults: nil)
        defer { controller.dispose() }
        let window = try XCTUnwrap(controller.window)
        window.makeFirstResponder(controller.textView)
        controller.textView.string = "edited\ncontent"
        controller.textDidChange(Notification(name: NSText.didChangeNotification))
        controller.applyLayout(.merged)
        XCTAssertEqual(controller.textView.string, "edited content")
        controller.textView.undoManager?.undo()
        XCTAssertEqual(controller.textView.string, "edited\ncontent")
        controller.textView.undoManager?.redo()
        XCTAssertEqual(controller.textView.string, "edited content")
    }
    func testModeSwitchCanRestoreOriginalLineStructureBeforeManualEdit() {
        let controller = ScreenshotOCRWindowController(result: .init(text: "原始\n折行", averageConfidence: 1), defaults: nil)
        defer { controller.dispose() }
        controller.applyLayout(.merged)
        XCTAssertEqual(controller.textView.string, "原始折行")
        controller.applyLayout(.lines)
        XCTAssertEqual(controller.textView.string, "原始\n折行")
    }
    func testCopyUsesCurrentEditedText() throws {
        var copied = ""
        let controller = ScreenshotOCRWindowController(result: .init(text: "original", averageConfidence: 1), defaults: nil, copy: { copied = $0; return true })
        defer { controller.dispose() }
        controller.textView.string = "current edit"
        controller.copyText()
        XCTAssertEqual(copied, "current edit")
    }
    func testUnpinnedOutsideClickClosesButPinnedWindowStays() {
        let controller = ScreenshotOCRWindowController(result: .init(text: "a", averageConfidence: 1), defaults: nil)
        XCTAssertFalse((controller.window as? NSPanel)?.hidesOnDeactivate ?? true, "系统不得在应用失活时绕过钉住状态自动隐藏面板")
        controller.showWindow(nil)
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let pin = controller.window?.contentView.flatMap { descendants($0).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "钉住" } }
        pin?.performClick(nil)
        XCTAssertTrue(controller.isPinned)
        controller.dismissForOutsideClick(nil)
        XCTAssertTrue(controller.window?.isVisible == true)
        controller.togglePin(); controller.dismissForOutsideClick(nil)
        XCTAssertFalse(controller.window?.isVisible == true)
    }
}

private actor OCRLanguageGate: TextRecognizing {
    private var continuation: CheckedContinuation<RecognizedOCRText, Never>?
    private(set) var started = false
    func recognizeText(in image: CGImage) async throws -> RecognizedOCRText {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ text: String) { continuation?.resume(returning: .init(text: text, averageConfidence: 1)); continuation = nil }
}

extension OCRResultWindowTests {
    func testLanguageChangePersistsAndRejectsLatePreviousResponseWithoutLosingEdits() async throws {
        let name = "OCRResultWindow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let old = OCRLanguageGate(), new = OCRLanguageGate()
        let controller = ScreenshotOCRWindowController(image: image(), result: .init(text: "edited text", averageConfidence: 1),
            recognizerFactory: { $0 == "ja-JP" ? new : old }, defaults: defaults, commonLanguages: ["ja"], supportedLanguages: ["en-US", "ja-JP"])
        defer { controller.dispose() }
        controller.togglePin()
        controller.selectLanguage("en-US")
        for _ in 0..<100 where !(await old.started) { try await Task.sleep(for: .milliseconds(5)) }
        controller.selectLanguage("ja-JP")
        for _ in 0..<100 where !(await new.started) { try await Task.sleep(for: .milliseconds(5)) }
        await new.finish("新しい結果")
        for _ in 0..<100 where controller.isRecognizing { try await Task.sleep(for: .milliseconds(5)) }
        await old.finish("obsolete result")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(defaults.string(forKey: OCRRecognitionLanguages.preferenceKey), "ja-JP")
        XCTAssertEqual(controller.textView.string, "新しい結果")
        XCTAssertTrue(controller.isPinned, "重新识别不能清除钉住状态")
        XCTAssertEqual(controller.window?.level, .floating)
        controller.textView.undoManager?.undo()
        XCTAssertEqual(controller.textView.string, "edited text")
    }
}

extension OCRResultWindowTests {
    func testLayoutModeAndOriginalVisibilityAndWindowGeometryPersistWithoutText() throws {
        let name = "OCRWindowPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let result = RecognizedOCRText(text: "原始\n换行", averageConfidence: 1)
        let first = ScreenshotOCRWindowController(image: image(), result: result, defaults: defaults)
        first.showWindow(nil)
        first.applyLayout(.merged)
        first.toggleOriginal()
        XCTAssertTrue(first.showsOriginal)
        let initialWidth = try XCTUnwrap(first.window).frame.width
        XCTAssertGreaterThanOrEqual(initialWidth, Design.OCR.minimumSize.width)
        let split = try XCTUnwrap(first.imagePreview?.superview?.superview as? NSSplitView)
        split.setPosition(Design.OCR.minimumPanelWidth + 60, ofDividerAt: 0)
        first.window?.contentView?.layoutSubtreeIfNeeded()
        let leftWidth = try XCTUnwrap(first.imagePreview).frame.width
        let frame = try XCTUnwrap(first.window).frame
        first.close()
        let reopened = ScreenshotOCRWindowController(image: image(), result: result, defaults: defaults)
        defer { reopened.dispose() }
        XCTAssertTrue(reopened.showsOriginal)
        XCTAssertEqual(reopened.layoutMode, .merged)
        XCTAssertEqual(reopened.textView.string, "原始换行")
        XCTAssertEqual(try XCTUnwrap(reopened.window).frame.width, frame.width, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(reopened.imagePreview).frame.width, leftWidth, accuracy: 1)
        let stored = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("ocr.") }
        XCTAssertFalse(stored.values.contains { String(describing: $0).contains(result.text) })
        reopened.showWindow(nil); reopened.toggleOriginal(); reopened.close()
        let hidden = ScreenshotOCRWindowController(image: image(), result: result, defaults: defaults)
        defer { hidden.dispose() }
        XCTAssertFalse(hidden.showsOriginal)
    }
}

@MainActor final class OCRImagePreviewTests: XCTestCase {
    func testZoomStaysUnderMouseAndDraggingMovesImageAndRightClickRestoresFit() throws {
        let image = NSImage(size: NSSize(width: 100, height: 50))
        let preview = OCRImagePreview(image: image)
        preview.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let original = preview.displayedImageRect
        XCTAssertEqual(original, CGRect(x: 0, y: 50, width: 400, height: 200))
        let point = CGPoint(x: 100, y: 100)
        let u = (point.x - original.minX) / original.width, v = (point.y - original.minY) / original.height
        preview.zoom(by: 2, around: point)
        let zoomed = preview.displayedImageRect
        XCTAssertEqual(zoomed.minX + u * zoomed.width, point.x, accuracy: 0.001)
        XCTAssertEqual(zoomed.minY + v * zoomed.height, point.y, accuracy: 0.001)
        preview.pan(by: CGPoint(x: 10, y: -5))
        XCTAssertEqual(preview.displayedImageRect.minX, zoomed.minX + 10, accuracy: 0.001)
        XCTAssertEqual(preview.displayedImageRect.minY, zoomed.minY - 5, accuracy: 0.001)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        preview.rightMouseDown(with: event)
        XCTAssertEqual(preview.zoom, 1); XCTAssertEqual(preview.offset, .zero)
        XCTAssertEqual(preview.displayedImageRect, original)
        XCTAssertFalse(preview.subviews.contains { $0 is NSScrollView })
    }
}

extension OCRResultLayoutTests {
    private func line(_ text: String, x: CGFloat = 0.1, y: CGFloat, width: CGFloat = 0.8, height: CGFloat = 0.04) -> OCRTextLine {
        .init(text: text, boundingBox: CGRect(x: x, y: y, width: width, height: height))
    }
    func testRestoredSmartLayoutMergesWrapsButPreservesParagraphGapsAndLists() {
        let lines = [line("这是一个", y: 0.9), line("完整段落。", y: 0.85), line("第二段", y: 0.7), line("的内容", y: 0.65), line("• 第一项", y: 0.55), line("• 第二项", y: 0.5)]
        XCTAssertEqual(OCRResultLayout.smart.apply(to: lines.map(\.text).joined(separator: "\n"), lines: lines), "这是一个完整段落。\n第二段的内容\n• 第一项\n• 第二项")
    }
    func testRestoredSmartLayoutDoesNotJoinAcrossColumnsOrLargeHeadings() {
        let lines = [line("Left", y: 0.9, width: 0.3), line("Right", x: 0.6, y: 0.9, width: 0.3), line("column", y: 0.85, width: 0.3), line("column", x: 0.6, y: 0.85, width: 0.3)]
        XCTAssertEqual(OCRResultLayout.smart.apply(to: lines.map(\.text).joined(separator: "\n"), lines: lines), "Left column\nRight column")
        let heading = [line("标题", y: 0.9, height: 0.08), line("段落正文", y: 0.84)]
        XCTAssertEqual(OCRResultLayout.smart.apply(to: "标题\n段落正文", lines: heading), "标题\n段落正文")
    }
}

extension OCRResultWindowTests {
    func testCloseButtonOnlyHidesAndReopenRestoresSameTextImageAndUndoHistory() throws {
        let controller = ScreenshotOCRWindowController(image: image(), result: .init(text: "before", averageConfidence: 1), defaults: nil)
        defer { controller.dispose() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window), preview = controller.imagePreview
        controller.replaceText("edited text", action: "编辑")
        var closeEvents = 0
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in closeEvents += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(closeEvents, 0, "关闭按钮只能orderOut，不能触发销毁清理")
        controller.showWindow(nil)
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(controller.imagePreview === preview)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(controller.textView.string, "edited text")
        controller.textView.undoManager?.undo()
        XCTAssertEqual(controller.textView.string, "before")
        controller.dispose()
        XCTAssertEqual(closeEvents, 1)
    }
}

extension OCRResultWindowTests {
    func testReplacingImageKeepsPinnedStateAndOutsideClicksDoNotHideNewResult() throws {
        let previous = ScreenshotOCRWindowController(image: image(), result: .init(text: "old image", averageConfidence: 1), defaults: nil)
        previous.showWindow(nil); previous.togglePin(); previous.close()
        let replacement = ScreenshotOCRWindowController(image: image(), result: .init(text: "new image", averageConfidence: 1), defaults: nil)
        defer { replacement.dispose() }
        replacement.inheritPinState(from: previous)
        previous.dispose()
        replacement.showWindow(nil)
        XCTAssertTrue(replacement.isPinned)
        XCTAssertEqual(replacement.window?.level, .floating)
        XCTAssertEqual(replacement.textView.string, "new image")
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let pin = try XCTUnwrap(descendants(try XCTUnwrap(replacement.window?.contentView)).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "钉住" })
        XCTAssertEqual(pin.accessibilityValue() as? String, "已钉住")
        replacement.dismissForOutsideClick(nil)
        XCTAssertTrue(replacement.window?.isVisible == true)
        replacement.inheritPinState(from: replacement)
        XCTAssertTrue(replacement.isPinned, "重新打开同一窗口不能再次翻转状态")
    }
    func testReplacingUnpinnedResultStaysUnpinnedAndDoesNotPersistPinAsContentPreference() throws {
        let suite = "OCRPinSession.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let previous = ScreenshotOCRWindowController(result: .init(text: "old", averageConfidence: 1), defaults: defaults)
        previous.togglePin(); previous.togglePin()
        let replacement = ScreenshotOCRWindowController(result: .init(text: "new", averageConfidence: 1), defaults: defaults)
        defer { replacement.dispose() }
        replacement.inheritPinState(from: previous); previous.dispose()
        replacement.showWindow(nil)
        XCTAssertFalse(replacement.isPinned)
        replacement.dismissForOutsideClick(nil)
        XCTAssertFalse(replacement.window?.isVisible == true)
        XCTAssertFalse(defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("ocr.") && $0.localizedCaseInsensitiveContains("pin") })
    }
}
