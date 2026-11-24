import AppKit
import Carbon
import XCTest
@testable import Seven

@MainActor final class ScreenshotSharingFlowTests:XCTestCase {
    private func image() -> NSImage {
        let image=NSImage(size:CGSize(width:320,height:240));image.lockFocus();NSColor.white.setFill();CGRect(x:0,y:0,width:320,height:240).fill();image.unlockFocus();return image
    }
    private func key(_ value:String,code:UInt16=0,flags:NSEvent.ModifierFlags=[] )throws->NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:value,charactersIgnoringModifiers:value,isARepeat:false,keyCode:code))
    }
    func testShareServiceLowersWholeWindowFamilyWithoutHidingAndRestoresOnCancel() throws {
        let root=NSPanel(contentRect:CGRect(x:0,y:0,width:320,height:240),styleMask:.borderless,backing:.buffered,defer:false)
        let tools=NSPanel(contentRect:CGRect(x:0,y:0,width:200,height:40),styleMask:.borderless,backing:.buffered,defer:false)
        root.isReleasedWhenClosed=false;tools.isReleasedWhenClosed=false;root.level = .statusBar;tools.level = .popUpMenu
        root.addChildWindow(tools,ordered:.above);root.orderFrontRegardless();tools.orderFrontRegardless()
        defer{root.removeChildWindow(tools);tools.close();root.close()}
        let rootLevel=root.level,toolsLevel=tools.level
        let service=try XCTUnwrap(NSSharingService(named:.composeEmail)),picker=NSSharingServicePicker(items:[])
        var activity:[Bool]=[]
        let session=try ScreenshotSharingSession(image:image(),windows:[root],activityChanged:{activity.append($0)})
        XCTAssertEqual(root.level,rootLevel,"打开菜单不降层")
        session.sharingServicePicker(picker,didChoose:service)
        session.sharingService(service,willShareItems:[])
        XCTAssertEqual(root.level,.normal);XCTAssertEqual(tools.level,.normal)
        XCTAssertTrue(root.isVisible);XCTAssertTrue(tools.isVisible);XCTAssertEqual(activity,[true])
        session.sharingService(service,didFailToShareItems:[],error:CocoaError(.userCancelled))
        XCTAssertEqual(root.level,rootLevel);XCTAssertEqual(tools.level,toolsLevel)
        XCTAssertTrue(root.isVisible);XCTAssertTrue(tools.isVisible);XCTAssertEqual(activity,[true,false])
        session.sharingService(service,didShareItems:[]);XCTAssertEqual(activity,[true,false],"重复回调不能重复恢复")
    }
    func testSharedCompanionAndClosedWindowsAreNotResurrected() throws {
        let pin=ScreenshotPinWindowController(image:image(),preferences:ScreenshotPinPreferences());defer{pin.close()}
        ScreenshotAuxiliaryWindows.show(pin,activateApplication:false)
        let editor=try XCTUnwrap(pin.makeEditor(preferences:ScreenshotToolPreferences()))
        ScreenshotAuxiliaryWindows.show(editor,activateApplication:false);defer{editor.close()}
        let root=try XCTUnwrap(editor.window),companion=try XCTUnwrap(editor.sharingCompanionWindow)
        let session=try ScreenshotSharingSession(image:image(),windows:[root,companion])
        let service=try XCTUnwrap(NSSharingService(named:.composeEmail))
        session.sharingService(service,willShareItems:[])
        XCTAssertEqual(root.level,.normal);XCTAssertEqual(companion.level,.normal)
        editor.close();pin.close()
        session.sharingService(service,didShareItems:[])
        XCTAssertFalse(root.isVisible);XCTAssertFalse(companion.isVisible)
    }
    func testHiddenPinRestoresItsLevelWithoutBeingShown() throws {
        let pin=ScreenshotPinWindowController(image:image(),preferences:ScreenshotPinPreferences());defer{pin.close()}
        ScreenshotAuxiliaryWindows.show(pin,activateApplication:false)
        let root=try XCTUnwrap(pin.window),level=root.level
        let session=try ScreenshotSharingSession(image:image(),windows:[root])
        let service=try XCTUnwrap(NSSharingService(named:.composeEmail))
        session.sharingService(service,willShareItems:[])
        pin.setVisible(false)
        session.sharingService(service,didShareItems:[])
        XCTAssertEqual(root.level,level);XCTAssertFalse(root.isVisible)
        pin.setVisible(true);XCTAssertTrue(root.isVisible);XCTAssertEqual(root.level,level)
    }
    func testChoosingDestinationCompletesCaptureOnceButKeepsFileForService() throws {
        let root=NSWindow(contentRect:CGRect(x:0,y:0,width:320,height:240),styleMask:.borderless,backing:.buffered,defer:false)
        root.isReleasedWhenClosed=false;root.orderFrontRegardless();defer{root.close()}
        var completed=0
        let session=try ScreenshotSharingSession(image:image(),windows:[root],serviceChosen:{completed+=1;root.close()})
        let service=try XCTUnwrap(NSSharingService(named:.composeEmail)),picker=NSSharingServicePicker(items:[])
        session.sharingServicePicker(picker,didChoose:service)
        session.sharingService(service,willShareItems:[])
        XCTAssertEqual(completed,1);XCTAssertFalse(root.isVisible)
        XCTAssertTrue(FileManager.default.fileExists(atPath:session.fileURL.path))
        session.sharingService(service,didFailToShareItems:[],error:CocoaError(.userCancelled))
        XCTAssertFalse(root.isVisible);XCTAssertFalse(FileManager.default.fileExists(atPath:session.fileURL.path))
        let cancelled=try ScreenshotSharingSession(image:image(),serviceChosen:{completed+=1})
        cancelled.sharingServicePicker(picker,didChoose:nil);XCTAssertEqual(completed,1)
    }
    func testInitialFocusIsCanvasAndExplicitClickCanStillEditDimensions() throws {
        let cg=try XCTUnwrap(image().cgImage(forProposedRect:nil,context:nil,hints:nil))
        let context=FrozenSelectionContext(screenFrame:CGRect(x:0,y:0,width:320,height:240),localSelection:CGRect(x:20,y:20,width:180,height:100),image:cg)
        let editor=ScreenshotEditorWindowController(image:try XCTUnwrap(context.croppedImage(in:context.localSelection)),context: .selection(context),preferences:ScreenshotToolPreferences());defer{editor.close()}
        editor.showWindow(nil)
        let root=try XCTUnwrap(editor.window),size=try XCTUnwrap(root.childWindows?.first{$0.title=="截图尺寸"})
        XCTAssertTrue(root.firstResponder is ScreenshotEditorCanvas)
        XCTAssertFalse(size.firstResponder is NSTextView);XCTAssertFalse(size.firstResponder is NSTextField)
        func views(_ view:NSView)->[NSView] {view.subviews+view.subviews.flatMap(views)}
        let field=try XCTUnwrap(size.contentView.flatMap{views($0).compactMap{$0 as? NSTextField}.first{$0.isEditable}})
        size.makeKey();XCTAssertTrue(size.makeFirstResponder(field))
        XCTAssertTrue(size.firstResponder is NSTextView)
    }
    func testUnifiedRecorderChecksBothPoliciesAndReservedResetKey() throws {
        func assertRejected(_ attempt: ShortcutCaptureAttempt, line: UInt = #line) {
            guard case let .failed(reason) = attempt else {
                XCTFail("预期拒绝录制，实际结果为 \(attempt)", line: line)
                return
            }
            XCTAssertFalse(reason.isEmpty, line: line)
        }
        let manager=HotKeyManager(defaults:nil,allowsUnset:true,scope:.local)
        let combination=ShortcutCaptureTarget.combination(manager)
        assertRejected(combination.record(try key("k",code:UInt16(kVK_ANSI_K))))
        let configured=combination.record(try key("k",code:UInt16(kVK_ANSI_K),flags:[.command,.option]))
        XCTAssertEqual(configured,.saved(["⌥","⌘","K"]))
        let preferences=ScreenshotToolbarPreferences(),single=ShortcutCaptureTarget.tool(.share,preferences)
        assertRejected(single.record(try key("c",flags:.command)))
        assertRejected(single.record(try key("r",code:15)))
        assertRejected(single.record(try key("\r",code:36)))
        assertRejected(single.record(try key("!")))
        XCTAssertEqual(single.record(try key("q")),.saved(["Q"]))
        XCTAssertEqual(preferences.item(.share).key,"q")
        XCTAssertFalse(preferences.setKey("r",for:.ocr))
        XCTAssertTrue(preferences.setKey("r",for:.rectangle),"只在长图采集场景保留R，其他场景仍可复用")
        XCTAssertEqual(preferences.hint(.reset),"R");XCTAssertFalse(preferences.setKey("t",for:.reset))
        XCTAssertEqual(preferences.action(for:try key("r",code:15),context:.longCapture),.reset)
        XCTAssertEqual(preferences.action(for:try key("r",code:15),context:.screenshotEdit),.rectangle)
    }
    func testLongCaptureDoesNotSampleDuringShareAndResumesAfterward() async throws {
        var captures=0
        let cg=try XCTUnwrap(image().cgImage(forProposedRect:nil,context:nil,hints:nil))
        let capture=ScreenshotScrollWindowController(rect:CGRect(x:100,y:100,width:320,height:240),capture:{_,_ in captures+=1;return cg},completed:{_ in})
        defer{capture.close()}
        capture.sample();await capture.sampling?.value;XCTAssertEqual(captures,1)
        capture.setSharingServiceActive(true);XCTAssertTrue(capture.sharingServiceActive)
        capture.tick();capture.sample();XCTAssertEqual(captures,1)
        capture.setSharingServiceActive(false);XCTAssertFalse(capture.sharingServiceActive)
        capture.sample();await capture.sampling?.value;XCTAssertEqual(captures,2)
        capture.close();capture.setSharingServiceActive(false);capture.sample();XCTAssertEqual(captures,2)
    }
}
