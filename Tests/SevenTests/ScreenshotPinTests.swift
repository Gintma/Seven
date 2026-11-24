import AppKit
import XCTest
@testable import Seven

final class ScreenshotPinTests: XCTestCase {
    func testPinResizeKeepsMouseAnchorAndAspectRatio() {
        let base = NSSize(width: 100, height: 50)
        let old = NSRect(x: 20, y: 30, width: 100, height: 50)
        let mouse = NSPoint(x: 40, y: 60)
        let changed = ScreenshotPinGeometry.resized(base: base, old: old, mouse: mouse, requestedScale: 200)
        XCTAssertEqual((mouse.x - changed.frame.minX) / changed.frame.width, (mouse.x - old.minX) / old.width, accuracy: 0.01)
        XCTAssertEqual((mouse.y - changed.frame.minY) / changed.frame.height, (mouse.y - old.minY) / old.height, accuracy: 0.01)
        XCTAssertEqual(changed.frame.width / changed.frame.height, base.width / base.height, accuracy: 0.01)
        XCTAssertGreaterThan(changed.frame.width, old.width)
    }

    @MainActor private func image() -> NSImage {
        let source = NSImage(size:NSSize(width:120,height:90));source.lockFocus()
        ThemePalette.system.accent.setFill();CGRect(x:0,y:0,width:120,height:90).fill();source.unlockFocus()
        return source
    }
    @MainActor private func pasteboard() -> NSPasteboard { NSPasteboard.withUniqueName() }
    @MainActor private func event(_ type:NSEvent.EventType = .rightMouseDown) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with:type,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1))
    }
    func testVeryTallPinCanZoomFromSubPercentFitWithoutZeroDivision() {
        let result = ScreenshotPinGeometry.resized(base:CGSize(width:400,height:100000),old:CGRect(x:10,y:10,width:1,height:250),mouse:CGPoint(x:10.5,y:100),requestedScale:1)
        XCTAssertTrue(result.frame.minX.isFinite);XCTAssertTrue(result.frame.minY.isFinite)
        XCTAssertGreaterThan(result.frame.width,0)
    }
    @MainActor func testLiveWheelPreferencesCanUsePlainWheelAndDefaultsRoundTrip() throws {
        let suite="SevenPinPrefs.\(UUID().uuidString)",defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite)}
        let preferences=ScreenshotPinPreferences(defaults:defaults)
        defaults.set(ScreenshotPinWheel.plain.rawValue,forKey:ScreenshotPinPreferences.zoomKey)
        defaults.set(ScreenshotPinWheel.control.rawValue,forKey:ScreenshotPinPreferences.opacityWheelKey)
        XCTAssertEqual(preferences.zoomWheel,.plain);XCTAssertEqual(preferences.opacityWheel,.control)
        let controller=ScreenshotPinWindowController(image:image(),preferences:preferences);defer {controller.close()}
        let view=try XCTUnwrap(controller.window?.contentView as? ScreenshotPinnedImageView)
        let originalOpacity = view.displayOpacity
        func wheel(_ modifiers:CGEventFlags) throws -> NSEvent {
            let event=try XCTUnwrap(CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:-5,wheel2:0,wheel3:0));event.flags=modifiers
            return try XCTUnwrap(NSEvent(cgEvent:event))
        }
        let old=try XCTUnwrap(controller.window).frame
        view.scrollWheel(with:try wheel([]));XCTAssertLessThan(try XCTUnwrap(controller.window).frame.width,old.width)
        let scaled=try XCTUnwrap(controller.window).frame
        view.scrollWheel(with:try wheel(.maskControl));XCTAssertLessThan(view.displayOpacity, originalOpacity)
        XCTAssertEqual(controller.window?.frame,scaled)
        view.scrollWheel(with:try wheel(.maskCommand));XCTAssertEqual(controller.window?.frame,scaled)
    }

    @MainActor func testOriginalImageSurvivesDisplayAndIgnoresRemovedDefaults() throws {
        let suite="SevenPinTests.\(UUID().uuidString)",defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set(12.0,forKey:"screenshotPin.radius.v1");defaults.set(0.5,forKey:"screenshotPin.opacity.v1")
        let original=image(),controller=ScreenshotPinWindowController(image:original,preferences:.init(defaults:defaults))
        defer {controller.close()}
        let window = try XCTUnwrap(controller.window)
        let panel = ScreenshotSaving.makePanel(parent: window, format: .png)
        XCTAssertGreaterThan(panel.level.rawValue, window.level.rawValue)
        let output=try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(controller.pngData())))
        XCTAssertEqual(try XCTUnwrap(output.colorAt(x:0,y:0)).alphaComponent,1,accuracy:0.01)
        let board=pasteboard();defer {board.releaseGlobally()}
        controller.copyImage(to:board)
        let copied=try ScreenshotClipboardPin.image(from:board)
        XCTAssertEqual(copied.size,original.size)
    }
    @MainActor func testShrinkingRetinaPinDoesNotReduceSavedPixelDimensions() throws {
        let rep=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:400,pixelsHigh:200,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        rep.bitmapData?.initialize(repeating:0,count:rep.bytesPerRow*rep.pixelsHigh)
        rep.size=CGSize(width:200,height:100)
        let image=NSImage(size:rep.size);image.addRepresentation(rep)
        let controller=ScreenshotPinWindowController(image:image,preferences:.init());defer{controller.close()}
        controller.window?.setContentSize(CGSize(width:50,height:25))
        let output=try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(controller.pngData())))
        XCTAssertEqual(output.pixelsWide,400);XCTAssertEqual(output.pixelsHigh,200)
    }

    @MainActor func testMenuClosesAllPinsAndHoverButtonClosesCurrentPin() throws {
        let controller=ScreenshotPinWindowController(image:image(),preferences:.init());defer {controller.close()}
        let view=try XCTUnwrap(controller.window?.contentView as? ScreenshotPinnedImageView)
        let menu=try XCTUnwrap(view.menu(for:try event()))
        var closedAll=false;controller.onCloseAll={closedAll=true}
        let all = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("closeAllPins") })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(all.action), to: all.target, from: all))
        XCTAssertTrue(closedAll)
        let close = try XCTUnwrap(view.subviews.compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("closePin") })
        XCTAssertTrue(close.isHidden);view.mouseEntered(with:try event());XCTAssertFalse(close.isHidden)
        view.layoutSubtreeIfNeeded();XCTAssertGreaterThan(close.frame.width,0);XCTAssertTrue(view.bounds.contains(close.frame))
        let hit = view.convert(CGPoint(x:close.frame.midX,y:close.frame.midY),to:view.superview)
        XCTAssertTrue(view.hitTest(hit) === close, "鼠标点击叉号必须命中关闭按钮，不能被图片截获")
        close.performClick(nil);XCTAssertTrue(controller.isClosed)
    }
    func testWheelChoicesIncludePlainAndRequireExactModifierCombination() {
        XCTAssertTrue(ScreenshotPinWheel.plain.matches([]));XCTAssertTrue(ScreenshotPinWheel.plain.matches(.capsLock))
        for choice in ScreenshotPinWheel.allCases {
            XCTAssertEqual(ScreenshotPinWheel.available(excluding: choice).count, ScreenshotPinWheel.allCases.count-1)
            XCTAssertFalse(ScreenshotPinWheel.available(excluding: choice).contains(choice))
            XCTAssertTrue(choice.matches(choice.flags))
            for other in ScreenshotPinWheel.allCases where choice != other {XCTAssertFalse(choice.matches(other.flags))}
        }
        XCTAssertFalse(ScreenshotPinWheel.command.matches([.command,.option]))
    }
    @MainActor func testClipboardTextKeepsLayoutSizeAtRetinaDensity() throws {
        let text = "第一行\nSecond line"
        let standard = try ScreenshotClipboardPin.textImage(text, scale: 1)
        let retina = try ScreenshotClipboardPin.textImage(text, scale: 2)
        let standardBitmap = try XCTUnwrap(standard.representations.first as? NSBitmapImageRep)
        let retinaBitmap = try XCTUnwrap(retina.representations.first as? NSBitmapImageRep)

        XCTAssertEqual(standard.size, retina.size)
        XCTAssertEqual(retinaBitmap.size, standard.size)
        XCTAssertEqual(retinaBitmap.pixelsWide, standardBitmap.pixelsWide * 2)
        XCTAssertEqual(retinaBitmap.pixelsHigh, standardBitmap.pixelsHigh * 2)
    }

    @MainActor func testClipboardTextAndImagePriorityUseOnlyIsolatedPasteboard() throws {
        let board=pasteboard();defer{board.releaseGlobally()}
        XCTAssertThrowsError(try ScreenshotClipboardPin.image(from:board))
        board.setString("第一行\nSecond line\n第三行",forType:.string)
        let textImage=try ScreenshotClipboardPin.image(from:board)
        XCTAssertGreaterThan(textImage.size.height,Design.Text.content.nsFont.pointSize*3)
        let original=image();board.clearContents();board.writeObjects([original]);board.setString("应优先使用图片",forType:.string)
        XCTAssertEqual(try ScreenshotClipboardPin.image(from:board).size,original.size)
    }
    @MainActor func testToggleAndCloseAllPinsLeaveOtherAuxiliaryWindowsAlone() throws {
        _ = NSApplication.shared
        let a=ScreenshotPinWindowController(image:image(),preferences:.init()),b=ScreenshotPinWindowController(image:image(),preferences:.init())
        let other=NSWindowController(window:NSWindow(contentRect:CGRect(x:0,y:0,width:100,height:100),styleMask:[.titled],backing:.buffered,defer:false))
        other.window?.isReleasedWhenClosed=false
        defer {a.close();b.close();other.close()}
        for controller in [a,b,other] {ScreenshotAuxiliaryWindows.show(controller,activateApplication:false)}
        ScreenshotAuxiliaryWindows.togglePins();XCTAssertFalse(a.window?.isVisible ?? true);XCTAssertTrue(other.window?.isVisible ?? false)
        ScreenshotAuxiliaryWindows.togglePins();XCTAssertTrue(a.window?.isVisible ?? false);XCTAssertTrue(b.window?.isVisible ?? false)
        ScreenshotAuxiliaryWindows.closeAllPins();XCTAssertTrue(a.isClosed);XCTAssertTrue(b.isClosed);XCTAssertTrue(other.window?.isVisible ?? false)
        ScreenshotAuxiliaryWindows.togglePins();XCTAssertFalse(a.window?.isVisible ?? true)
    }
    @MainActor func testOptionalPinHotKeyStartsUnsetClearsAndRoundTripsWithoutRegisteringPlaceholder() throws {
        let suite="SevenPinKeys.\(UUID().uuidString)",defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite)}
        let manager=HotKeyManager(defaults:defaults,storageKey:"pin",identifierID:905,allowsUnset:true)
        defer {manager.stop()}
        XCTAssertFalse(manager.isEnabled);XCTAssertNil(defaults.data(forKey:"pin"))
        var fired=false;manager.onHotKey={fired=true};manager.fire();XCTAssertFalse(fired)
        manager.start();XCTAssertFalse(manager.isRegistered);manager.suspend();manager.resume();XCTAssertFalse(manager.isRegistered)
        let candidate=KeyboardShortcut.inputDefault
        defaults.set(try JSONEncoder().encode(candidate),forKey:"pin")
        let restored=HotKeyManager(defaults:defaults,storageKey:"pin",identifierID:906,allowsUnset:true)
        defer {restored.stop()}
        XCTAssertTrue(restored.isEnabled);XCTAssertEqual(restored.shortcut,candidate)
        restored.clear();XCTAssertFalse(restored.isEnabled);XCTAssertNil(defaults.data(forKey:"pin"))
    }
    @MainActor func testLongClipboardTextIncludesTheWholeFinalLine() async throws {
        let text = "完成，已提交 dec8a15 并重新打包。\n" + [
            "- 钉图去边框，保留可隐藏的阴影，左上角悬停显示叉号。",
            "- 右键菜单按讨论调整，包含关闭和关闭所有。",
            "- 新增截图里的钉图设置，支持默认圆角、不透明度、滚轮组合及两个默认留空的全局快捷键。",
            "- 支持从剪贴板生成图片、文字钉图。",
            "- 钉图编辑复用长图的居中覆盖层。",
            "- 长截图提示改用正文色，单位为 px，删除编辑说明。",
            "FINAL LINE COMPLETE"
        ].joined(separator:"\n")
        let image = try ScreenshotClipboardPin.textImage(text)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
        let recognized = try await ScreenshotImageTextRecognizer().recognizeText(in:cg)
        XCTAssertTrue(recognized.text.contains("FINAL LINE COMPLETE"), "重新换行后仍须完整绘出最后一行")
    }
    @MainActor func testClosingPinDestroysControllerAndViewAndCannotBeRestored() async throws {
        var controller:ScreenshotPinWindowController? = ScreenshotPinWindowController(image:image(),preferences:.init())
        weak let weakController = controller
        weak let weakView = controller?.window?.contentView
        ScreenshotAuxiliaryWindows.show(try XCTUnwrap(controller),activateApplication:false)
        controller?.close();controller = nil
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertNil(weakController,"关闭后移除持有者，不能只orderOut隐藏")
        XCTAssertNil(weakView,"钉图视图及图片应随关闭释放")
        ScreenshotAuxiliaryWindows.togglePins()
        XCTAssertNil(weakController)
    }
}
