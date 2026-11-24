import AppKit
import Carbon
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Seven

@MainActor final class ImageImportTests: XCTestCase {
    private func pixels() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 1, y: 1, width: 10, height: 6))
        return try XCTUnwrap(context.makeImage())
    }
    func testLocalImagePreservesPixelSizeAlphaAndFileAndAppliesOrientation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try pixels()
        for (type, orientation) in [(UTType.png, 1), (.tiff, 6)] {
            let url = folder.appendingPathComponent("sample." + (type.preferredFilenameExtension ?? "image"))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, source, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let bytes = try Data(contentsOf: url)
            let image = try ImageImport.file(url)
            XCTAssertEqual(image.size, orientation == 6 ? CGSize(width: 8, height: 12) : CGSize(width: 12, height: 8))
            XCTAssertEqual(try Data(contentsOf: url), bytes, "导入不得改写源文件")
            let bitmap = try XCTUnwrap(ScreenshotSaving.bitmap(image))
            XCTAssertTrue(bitmap.hasAlpha)
            XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent, 0)
        }
    }
    func testBrokenOrRemoteImageIsRejectedWithoutNetworkOrWrites() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data("not an image".utf8); try bytes.write(to: url)
        XCTAssertThrowsError(try ImageImport.file(url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertThrowsError(try ImageImport.file(try XCTUnwrap(URL(string: "https://example.invalid/image.png"))))
    }
    func testClipboardImportAcceptsImagesButNeverTreatsPlainTextAsOCRImage() throws {
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        pasteboard.setString("plain text", forType: .string)
        XCTAssertThrowsError(try ImageImport.clipboard(pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "plain text")
        pasteboard.clearContents()
        let image = NSImage(cgImage: try pixels(), size: CGSize(width: 6, height: 4))
        pasteboard.writeObjects([image])
        let imported = try ImageImport.clipboard(pasteboard)
        XCTAssertEqual(imported.size, CGSize(width: 12, height: 8), "剪贴板图片按物理像素导入")
    }
    func testFileAssociationMatchesLoaderAndDoesNotClaimDefaultOwnership() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Info.plist")), format: nil) as? [String: Any])
        let types = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let imageType = try XCTUnwrap(types.first)
        XCTAssertEqual(imageType["CFBundleTypeRole"] as? String, "Viewer")
        XCTAssertEqual(imageType["LSHandlerRank"] as? String, "Alternate")
        XCTAssertEqual(Set(imageType["LSItemContentTypes"] as? [String] ?? []), Set(ImageImport.supportedTypes.map(\.identifier)))
    }
    func testImageEntryShortcutsDefaultUnsetAndAssignmentsPersist() throws {
        let suite = "ImageEntryShortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = ImageEntryShortcuts(defaults: defaults), ocr = OCRShortcuts(defaults: defaults)
        XCTAssertTrue((shortcuts.managers + ocr.managers).allSatisfy { !$0.isEnabled && !$0.isRegistered })
        let key = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_9), carbonModifiers: UInt32(controlKey | optionKey), keyLabel: "9")
        for storage in ["scrollCaptureHotKey.v1", "openImageHotKey.v1", "openClipboardImageHotKey.v1", "ocr.clipboardHotKey.v1", "ocr.fileHotKey.v1"] {
            defaults.set(try JSONEncoder().encode(key), forKey: storage)
        }
        let restored = ImageEntryShortcuts(defaults: defaults), recognized = OCRShortcuts(defaults: defaults)
        XCTAssertTrue((restored.managers + [recognized.clipboard, recognized.file]).allSatisfy { $0.shortcut == key && !$0.isRegistered })
    }
}

extension OCRImagePreviewTests {
    func testSingleClickOnSurroundingBlankResetsFitButDraggingOrImageClickDoesNot() throws {
        let preview = OCRImagePreview(image: NSImage(size: NSSize(width: 300, height: 50)))
        preview.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        preview.zoom(by: 2, around: CGPoint(x: 150, y: 150))
        preview.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 150, y: 150)))
        preview.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 150, y: 150)))
        XCTAssertEqual(preview.zoom, 2, "图片内点击不复原")
        preview.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 10, y: 10)))
        preview.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 20, y: 20)))
        preview.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 20, y: 20)))
        XCTAssertEqual(preview.zoom, 2, "空白处拖图不复原")
        preview.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 10, y: 10)))
        preview.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 10, y: 10)))
        XCTAssertEqual(preview.zoom, 1); XCTAssertEqual(preview.offset, .zero)
    }
}

extension ImageImportTests {
    func testImportedImageUsesExistingCenteredEditorAndExportsOriginalPixels() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 128, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: NSSize(width: 256, height: 128))
        var output: NSImage?
        let editor = ScreenshotEditorWindowController(image: image, context: .centered(.init(screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100), background: nil)), preferences: ScreenshotToolPreferences(), clipboardWriter: { output = $0; return false })
        defer { editor.close() }
        XCTAssertTrue(editor.window is ScreenshotEditorOverlayPanel)
        XCTAssertNil(editor.captureRect, "导入静态图片不是当前屏幕的可滚动选区")
        editor.performScrollAction(.copy)
        let bitmap = try XCTUnwrap(ScreenshotSaving.bitmap(try XCTUnwrap(output)))
        XCTAssertEqual(bitmap.pixelsWide, 256); XCTAssertEqual(bitmap.pixelsHigh, 128)
    }
}

extension ImageImportTests {
    func testOCRFileDropOnlyAcceptsLocalFilesAndKeepsTheirOrder() throws {
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        pasteboard.setString("ordinary text", forType: .string)
        XCTAssertTrue(OCRImageDropView.fileURLs(from: pasteboard).isEmpty)
        pasteboard.clearContents()
        pasteboard.writeObjects([try XCTUnwrap(NSURL(string: "https://example.invalid/image.png"))])
        XCTAssertTrue(OCRImageDropView.fileURLs(from: pasteboard).isEmpty)
        pasteboard.clearContents()
        let first = URL(fileURLWithPath: "/tmp/image-one.png"), second = URL(fileURLWithPath: "/tmp/image-two.jpg")
        pasteboard.writeObjects([first as NSURL, second as NSURL])
        XCTAssertEqual(OCRImageDropView.fileURLs(from: pasteboard), [first, second])
    }
}

extension ImageImportTests {
    func testFinderFileURLTakesPriorityOverFileIconForAllClipboardImageEntries() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try pixels(), rep = NSBitmapImageRep(cgImage: source)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 128, height: 128)
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setData(try XCTUnwrap(icon.tiffRepresentation), forType: .tiff)
        pasteboard.writeObjects([item])
        for image in [try ImageImport.clipboard(pasteboard), try ScreenshotClipboardPin.image(from: pasteboard)] {
            let bitmap = try XCTUnwrap(ScreenshotSaving.bitmap(image))
            XCTAssertEqual(bitmap.pixelsWide, 12, "Finder文件引用不能被系统文件图标替代")
            XCTAssertEqual(bitmap.pixelsHigh, 8)
            let sample = try XCTUnwrap(bitmap.colorAt(x: 5, y: 3)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(sample.redComponent, 0.9)
            XCTAssertGreaterThan(sample.redComponent - sample.greenComponent, 0.6)
        }
    }
}

extension ImageImportTests {
    func testInvalidFileReferenceDoesNotPinItsIconOrItsPathAsText() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("not-an-image.txt")
        try Data("fixture".utf8).write(to: file)
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        item.setString(file.path, forType: .string)
        item.setData(try XCTUnwrap(NSWorkspace.shared.icon(forFile: file.path).tiffRepresentation), forType: .tiff)
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([item])
        XCTAssertThrowsError(try ImageImport.clipboard(pasteboard))
        XCTAssertThrowsError(try ScreenshotClipboardPin.image(from: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .fileURL), file.absoluteString)
    }
    func testFinderFileCopyWithoutIconIsAcceptedAndMultipleFilesAreRejected() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("image.png")
        try XCTUnwrap(NSBitmapImageRep(cgImage: try pixels()).representation(using: .png, properties: [:])).write(to: file)
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([file as NSURL])
        XCTAssertEqual(try ScreenshotClipboardPin.image(from: pasteboard).size, CGSize(width: 12, height: 8))
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL, folder.appendingPathComponent("another.png") as NSURL])
        XCTAssertThrowsError(try ImageImport.clipboard(pasteboard)) { error in
            guard case ImageImportError.multipleFiles = error else { return XCTFail("必须报告多文件，不读取文件图标") }
        }
    }
    func testBitmapPinKeepsRetinaLogicalSizeAndStillPrefersImageOverText() throws {
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        let image = NSImage(cgImage: try pixels(), size: CGSize(width: 6, height: 4))
        pasteboard.writeObjects([image])
        pasteboard.setString("image must win", forType: .string)
        let result = try ScreenshotClipboardPin.image(from: pasteboard)
        XCTAssertEqual(result.size, image.size, "本来就是位图的剪贴板保持原有Retina显示大小")
        XCTAssertEqual(ScreenshotSaving.bitmap(result)?.pixelsWide, 12)
        XCTAssertEqual(ScreenshotSaving.bitmap(result)?.pixelsHigh, 8)
    }
}
