import AppKit
import Carbon
import XCTest
@testable import Seven

private struct OCRFixtureRecognizer:TextRecognizing {
    let text:String
    func recognizeText(in image:CGImage) async throws -> RecognizedOCRText {.init(text:text,averageConfidence:1)}
}
private struct OCRFailingRecognizer:TextRecognizing {
    let error:ScreenshotTranslationError?
    func recognizeText(in image:CGImage) async throws -> RecognizedOCRText {
        if let error {throw error}
        throw NSError(domain:"private-image-content",code:1,userInfo:[NSLocalizedDescriptionKey:"do not expose source text"])
    }
}
private actor OCRHeldRecognizer:TextRecognizing {
    private var pending:CheckedContinuation<Void,Never>?
    private(set) var count=0
    func recognizeText(in image:CGImage) async throws -> RecognizedOCRText {
        count+=1
        if count==1 {await withCheckedContinuation{pending=$0};return .init(text:"old result",averageConfidence:1)}
        return .init(text:"new result",averageConfidence:1)
    }
    func release(){pending?.resume();pending=nil}
}

@MainActor final class OCRCoordinatorTests:XCTestCase {
    private func image() throws -> NSImage {
        let context=try XCTUnwrap(CGContext(data:nil,width:80,height:40,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        return NSImage(cgImage:try XCTUnwrap(context.makeImage()),size:CGSize(width:80,height:40))
    }
    private func waitForStart(_ recognizer:OCRHeldRecognizer) async throws {
        for _ in 0..<100 {if await recognizer.count>0 {return};try await Task.sleep(for:.milliseconds(2))}
        XCTFail("识别未开始")
    }
    func testStandardOCRReturnsResultWithoutWritingClipboard() async throws {
        var copied:[String]=[],result:RecognizedOCRText?
        let coordinator=OCRCoordinator(recognizer:OCRFixtureRecognizer(text:"本机 OCR\nSecond line"),copyText:{copied.append($0);return true})
        coordinator.start(image:try image(),mode:.standard,completed:{result=$0},failed:{XCTFail("\($0)")})
        await coordinator.task?.value
        XCTAssertEqual(result?.text,"本机 OCR\nSecond line");XCTAssertTrue(copied.isEmpty);XCTAssertNil(coordinator.task)
    }
    func testSilentOCRCopiesExactTextWithoutPresentingResult() async throws {
        var copied:[String]=[],completed=false
        let coordinator=OCRCoordinator(recognizer:OCRFixtureRecognizer(text:"第一行\n日本語\n  retained spacing"),copyText:{copied.append($0);return true})
        coordinator.start(image:try image(),mode:.silent,completed:{XCTAssertNil($0);completed=true},failed:{XCTFail("\($0)")})
        await coordinator.task?.value
        XCTAssertTrue(completed);XCTAssertEqual(copied,["第一行\n日本語\n  retained spacing"])
    }
    func testCancelRejectsLateRecognitionWithoutCallbacksOrClipboardChanges() async throws {
        let recognizer=OCRHeldRecognizer();var calls=0
        let coordinator=OCRCoordinator(recognizer:recognizer,copyText:{_ in calls+=1;return true})
        coordinator.start(image:try image(),mode:.silent,completed:{_ in calls+=1},failed:{_ in calls+=1})
        let task=coordinator.task;try await waitForStart(recognizer)
        coordinator.cancel();await recognizer.release();await task?.value
        XCTAssertEqual(calls,0);XCTAssertNil(coordinator.task)
    }
    func testNewRequestWinsWhenOldRecognizerIgnoresCancellation() async throws {
        let recognizer=OCRHeldRecognizer();var copied:[String]=[],results:[String]=[]
        let coordinator=OCRCoordinator(recognizer:recognizer,copyText:{copied.append($0);return true})
        coordinator.start(image:try image(),mode:.silent,completed:{_ in XCTFail("旧结果不可完成")},failed:{_ in XCTFail("旧结果不可报错")})
        let old=coordinator.task;try await waitForStart(recognizer)
        coordinator.start(image:try image(),mode:.standard,completed:{if let value=$0 {results.append(value.text)}},failed:{XCTFail("\($0)")})
        await coordinator.task?.value
        await recognizer.release();await old?.value
        XCTAssertEqual(results,["new result"]);XCTAssertTrue(copied.isEmpty);XCTAssertNil(coordinator.task)
    }
    func testEmptyAndFailedRecognitionPreserveClipboardAndUseFixedErrors() async throws {
        for recognizer in [OCRFixtureRecognizer(text:" \n ") as any TextRecognizing,OCRFailingRecognizer(error:.noText),OCRFailingRecognizer(error:nil)] {
            var copied=0,failure:OCRFailure?
            let coordinator=OCRCoordinator(recognizer:recognizer,copyText:{_ in copied+=1;return true})
            coordinator.start(image:try image(),mode:.silent,completed:{_ in XCTFail("不能成功")},failed:{failure=$0})
            await coordinator.task?.value
            XCTAssertEqual(copied,0);XCTAssertNotNil(failure)
            XCTAssertFalse(failure?.localizedDescription.contains("do not expose") ?? true)
        }
        let coordinator=OCRCoordinator(recognizer:OCRFixtureRecognizer(text:"ok"),copyText:{_ in false})
        var failure:OCRFailure?
        coordinator.start(image:try image(),mode:.silent,completed:{_ in XCTFail("复制失败不可成功")},failed:{failure=$0})
        await coordinator.task?.value;XCTAssertEqual(failure,.clipboardWriteFailed)
    }
    func testResultWindowUsesRecognizedTextWithoutAnotherOCRPassAndAllowsTranslation() throws {
        let controller=ScreenshotOCRWindowController(result:.init(text:"可编辑结果",averageConfidence:1),defaults:nil);defer{controller.dispose()}
        func views(_ view:NSView)->[NSView] {view.subviews+view.subviews.flatMap(views)}
        let all=views(try XCTUnwrap(controller.window?.contentView)),text=try XCTUnwrap(all.compactMap{$0 as? NSTextView}.first)
        XCTAssertEqual(text.string,"可编辑结果");XCTAssertTrue(text.isEditable)
        var translated:String?;controller.onTranslate={translated=$0}
        text.string="编辑后的结果"
        try XCTUnwrap(all.compactMap{$0 as? NSButton}.first{$0.accessibilityLabel()=="翻译"}).performClick(nil)
        XCTAssertEqual(translated,"编辑后的结果")
    }
    func testOCRCaptureImportAndOpenShortcutsDefaultUnsetAndRoundTrip() throws {
        let name="OCRShortcuts.\(UUID().uuidString)",defaults=try XCTUnwrap(UserDefaults(suiteName:name));defer{defaults.removePersistentDomain(forName:name)}
        let fresh=OCRShortcuts(defaults:defaults)
        XCTAssertEqual(fresh.managers.count,5)
        XCTAssertEqual(OCRMode.allCases,[.standard,.silent]);XCTAssertTrue(fresh.managers.allSatisfy{!$0.isEnabled && !$0.isRegistered})
        let first=KeyboardShortcut(keyCode:UInt32(kVK_ANSI_7),carbonModifiers:UInt32(controlKey|optionKey),keyLabel:"7")
        let second=KeyboardShortcut(keyCode:UInt32(kVK_ANSI_8),carbonModifiers:UInt32(controlKey|optionKey),keyLabel:"8")
        defaults.set(try JSONEncoder().encode(first),forKey:"ocr.captureHotKey.v1")
        defaults.set(try JSONEncoder().encode(second),forKey:"ocr.silentCaptureHotKey.v1")
        defaults.set(try JSONEncoder().encode(first),forKey:"ocr.openWindowHotKey.v1")
        let restored=OCRShortcuts(defaults:defaults)
        XCTAssertEqual(restored.manager(.standard).shortcut,first);XCTAssertEqual(restored.manager(.silent).shortcut,second)
        XCTAssertEqual(restored.openWindow.shortcut,first)
        XCTAssertTrue([restored.standard,restored.silent,restored.openWindow].allSatisfy{$0.isEnabled && !$0.isRegistered},"单测不得注册全局快捷键")
        XCTAssertTrue([restored.clipboard,restored.file].allSatisfy{!$0.isEnabled && !$0.isRegistered})
    }
}
