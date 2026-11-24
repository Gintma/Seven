import AppKit
import XCTest
@testable import Seven

@MainActor final class ScreenshotSharingTests:XCTestCase {
    private func image()->NSImage {
        let image=NSImage(size:CGSize(width:100,height:80))
        image.lockFocus();NSColor.white.setFill()
        CGRect(origin: .zero, size: image.size).fill()
        image.unlockFocus();return image
    }
    func testSharePNGUsesOriginalPixelsAndIsRemovedOnCancel() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let source=image(),session=try ScreenshotSharingSession(image:source,temporaryDirectory:folder)
        let output=try XCTUnwrap(NSBitmapImageRep(data:Data(contentsOf:session.fileURL))),original=try XCTUnwrap(ScreenshotSaving.bitmap(source))
        XCTAssertEqual(output.pixelsWide,original.pixelsWide);XCTAssertEqual(output.pixelsHigh,original.pixelsHigh)
        XCTAssertTrue(session.fileURL.lastPathComponent.hasPrefix("Seven_"));XCTAssertEqual(session.fileURL.pathExtension,"png")
        let mode=try FileManager.default.attributesOfItem(atPath:session.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue,0o600)
        session.sharingServicePicker(NSSharingServicePicker(items:[]),didChoose:nil)
        XCTAssertTrue(session.isFinished);XCTAssertFalse(FileManager.default.fileExists(atPath:session.fileURL.deletingLastPathComponent().path))
    }
    func testShareCleanupOnCompletionFailureAndRelease() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let service=try XCTUnwrap(NSSharingService(named:.composeEmail))
        let success=try ScreenshotSharingSession(image:image(),temporaryDirectory:folder)
        success.sharingService(service,didShareItems:[success.fileURL]);XCTAssertFalse(FileManager.default.fileExists(atPath:success.fileURL.path))
        let failure=try ScreenshotSharingSession(image:image(),temporaryDirectory:folder)
        failure.sharingService(service,didFailToShareItems:[failure.fileURL],error:CocoaError(.userCancelled))
        XCTAssertFalse(FileManager.default.fileExists(atPath:failure.fileURL.path))
        var unused:ScreenshotSharingSession?=try ScreenshotSharingSession(image:image(),temporaryDirectory:folder)
        let path=try XCTUnwrap(unused).fileURL;unused=nil
        XCTAssertFalse(FileManager.default.fileExists(atPath:path.path))
    }
}

extension ScreenshotSharingTests {
    func testExportShadowExpandsCanvasAndPreservesBodyWhilePinPNGStaysUnchanged() throws {
        let original=image(),plain=try XCTUnwrap(ScreenshotSaving.bitmap(original))
        let style=ScreenshotShadowStyle(enabled:true,opacity:0.4,rgb:0)
        let output=ScreenshotShadowRendering.image(original,style:style),bitmap=try XCTUnwrap(ScreenshotSaving.bitmap(output))
        XCTAssertGreaterThan(bitmap.pixelsWide,plain.pixelsWide);XCTAssertGreaterThan(bitmap.pixelsHigh,plain.pixelsHigh)
        let center=try XCTUnwrap(bitmap.colorAt(x:bitmap.pixelsWide/2,y:bitmap.pixelsHigh/2)).usingColorSpace(.deviceRGB)
        XCTAssertEqual(center?.redComponent ?? 0,1,accuracy:0.02)
        let pin=ScreenshotPinWindowController(image:original,preferences:ScreenshotPinPreferences());defer{pin.close()}
        let saved=try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(pin.pngData())))
        XCTAssertEqual(saved.pixelsWide,plain.pixelsWide);XCTAssertEqual(saved.pixelsHigh,plain.pixelsHigh)
    }
}
