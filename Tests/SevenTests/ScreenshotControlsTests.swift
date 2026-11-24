import AppKit
import Carbon
import XCTest
@testable import Seven

@MainActor final class ScreenshotControlsTests:XCTestCase {
    private func image()->NSImage {NSImage(size:CGSize(width:160,height:120))}
    private func key(_ text:String,code:UInt16=0,flags:NSEvent.ModifierFlags=[] )throws->NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code))
    }
    func testEveryCustomToolbarKeyHasAnAllowedUniqueDefaultAndResetsWithoutChangingVisibility() throws {
        let name="ToolbarReset.\(UUID().uuidString)",defaults=try XCTUnwrap(UserDefaults(suiteName:name));defer{defaults.removePersistentDomain(forName:name)}
        let preferences=ScreenshotToolbarPreferences(defaults:defaults)
        let actions=ScreenshotToolbarAction.allCases.filter(\.acceptsKey)
        for action in actions {
            let value=try XCTUnwrap(action.defaultKey)
            XCTAssertTrue(ScreenshotToolbarPreferences.isValidKey(value),action.title)
            XCTAssertEqual(preferences.item(action).key,value)
        }
        let defaultKeys = Set(actions.compactMap(\.defaultKey))
        XCTAssertEqual(defaultKeys.count, actions.count)
        let rectangleDefault = try XCTUnwrap(ScreenshotToolbarAction.rectangle.defaultKey)
        let customKey = try XCTUnwrap(ScreenshotToolbarAction.allowedKeys.first { !defaultKeys.contains($0) })
        XCTAssertTrue(preferences.setKey(customKey, for: .rectangle))
        XCTAssertEqual(preferences.item(.rectangle).key, customKey)
        preferences.setVisible(false, for: .rectangle)
        XCTAssertTrue(preferences.resetKey(.rectangle))
        XCTAssertEqual(preferences.item(.rectangle).key, rectangleDefault)
        XCTAssertFalse(preferences.item(.rectangle).visible)
        XCTAssertEqual(ScreenshotToolbarPreferences(defaults:defaults).item(.rectangle),preferences.item(.rectangle))
        for bad in ["!","中","é","10",""] {XCTAssertFalse(preferences.setKey(bad,for:.share))}
        XCTAssertFalse(preferences.setKey(rectangleDefault, for: .share))
        XCTAssertFalse(preferences.setKey(customKey, for: .save))
    }
    func testOldEmptyAndConflictingKeysAcquireUniqueDefaults() throws {
        let name="ToolbarDefaults.\(UUID().uuidString)",defaults=try XCTUnwrap(UserDefaults(suiteName:name));defer{defaults.removePersistentDomain(forName:name)}
        let actions = ScreenshotToolbarAction.allCases.filter(\.acceptsKey)
        let defaultKeys = Set(actions.compactMap(\.defaultKey))
        let sharedKey = try XCTUnwrap(ScreenshotToolbarAction.allowedKeys.first { !defaultKeys.contains($0) })
        let saved: [String: ScreenshotToolbarPreferences.Item] = [
            ScreenshotToolbarAction.rectangle.rawValue: .init(visible: false, key: sharedKey),
            ScreenshotToolbarAction.ellipse.rawValue: .init(visible: true, key: sharedKey),
            ScreenshotToolbarAction.ocr.rawValue: .init(visible: true, key: nil),
        ]
        defaults.set(try JSONEncoder().encode(saved),forKey:"screenshotToolbar.v1")
        let value=ScreenshotToolbarPreferences(defaults:defaults)
        let rectangleKey = try XCTUnwrap(value.item(.rectangle).key)
        let ellipseKey = try XCTUnwrap(value.item(.ellipse).key)
        let fallback = rectangleKey == sharedKey ? ScreenshotToolbarAction.ellipse : .rectangle
        XCTAssertNotEqual(rectangleKey, ellipseKey)
        XCTAssertTrue([rectangleKey, ellipseKey].contains(sharedKey))
        XCTAssertEqual(value.item(fallback).key, try XCTUnwrap(fallback.defaultKey))
        XCTAssertFalse(value.item(.rectangle).visible)
        XCTAssertEqual(value.item(.ocr).key, try XCTUnwrap(ScreenshotToolbarAction.ocr.defaultKey))
    }
    func testPinCloseCombinationIsLocalAndMenuUsesCurrentCombination() throws {
        let close=ScreenshotPinShortcuts.closeCurrent(defaults:nil),all=HotKeyManager(defaults:nil,allowsUnset:true,scope:.local)
        let shortcut=KeyboardShortcut(keyCode:UInt32(kVK_ANSI_K),carbonModifiers:UInt32(cmdKey|optionKey),keyLabel:"K")
        XCTAssertTrue(close.update(shortcut));XCTAssertFalse(close.isRegistered,"局部关闭不得注册系统全局按键")
        XCTAssertTrue(all.update(KeyboardShortcut(keyCode:UInt32(kVK_ANSI_J),carbonModifiers:UInt32(cmdKey|optionKey),keyLabel:"J")))
        let pin=ScreenshotPinWindowController(image:image(),preferences:ScreenshotPinPreferences(),closeShortcut:close,closeAllShortcut:all);defer{pin.close()}
        var closedAll=false;pin.onCloseAll={closedAll=true}
        XCTAssertTrue(pin.handleKey(try key("j",code:UInt16(kVK_ANSI_J),flags:[.command,.option])));XCTAssertTrue(closedAll);XCTAssertFalse(pin.isClosed)
        close.suspend();XCTAssertFalse(close.matches(try key("k",code:UInt16(kVK_ANSI_K),flags:[.command,.option])));close.resume()
        let view=try XCTUnwrap(pin.window?.contentView as? ScreenshotPinnedImageView)
        let event=try XCTUnwrap(NSEvent.mouseEvent(with:.rightMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1))
        let menu = try XCTUnwrap(view.menu(for: event))
        let closeItem = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("closePin") })
        let title = try XCTUnwrap(closeItem.attributedTitle).string
        XCTAssertTrue(title.hasSuffix("\t\(close.shortcut.displayName)"))
        XCTAssertTrue(pin.handleKey(try key("k",code:UInt16(kVK_ANSI_K),flags:[.command,.option])));XCTAssertTrue(pin.isClosed)
    }
    func testCompletionSoundOnlyPlaysOnSuccessfulCaptureAndCanBeDisabled() throws {
        let name="CaptureSound.\(UUID().uuidString)",defaults=try XCTUnwrap(UserDefaults(suiteName:name));defer{defaults.removePersistentDomain(forName:name)}
        XCTAssertTrue(ScreenshotCapturePreferences(defaults:defaults).completionSound)
        var played=0,succeeds=false
        let editor=makeScreenshotEditorForTesting(image:image(),preferences:ScreenshotToolPreferences(defaults:defaults),clipboardWriter:{_ in succeeds},soundPlayer:{played+=1});defer{editor.close()}
        XCTAssertTrue(editor.performShortcut(try key("\r",code:36)));XCTAssertEqual(played,0)
        succeeds=true
        XCTAssertTrue(editor.performShortcut(try key("\r",code:36)));XCTAssertEqual(played,1)
        editor.close();XCTAssertEqual(played,1)
        defaults.set(false,forKey:ScreenshotCapturePreferences.completionSoundKey)
        let silent=makeScreenshotEditorForTesting(image:image(),preferences:ScreenshotToolPreferences(defaults:defaults),clipboardWriter:{_ in true},soundPlayer:{played+=1});defer{silent.close()}
        XCTAssertTrue(silent.performShortcut(try key("\r",code:36)));XCTAssertEqual(played,1)
        let cancelled=makeScreenshotEditorForTesting(image:image(),preferences:ScreenshotToolPreferences(),soundPlayer:{played+=1});cancelled.close();XCTAssertEqual(played,1)
    }
}
