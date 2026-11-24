import AppKit
import XCTest
@testable import Seven

@MainActor final class ScreenshotCaptureSchedulingTests: XCTestCase {
    private func image() throws -> CGImage {
        let context=try XCTUnwrap(CGContext(data:nil,width:100,height:80,bitsPerComponent:8,bytesPerRow:400,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
    func testCadenceDoesNotRound108MillisecondsUpTo200() {
        XCTAssertEqual(ScreenshotScrollPolicy.delayUntilNextSample(elapsed:0.108),0)
        XCTAssertEqual(ScreenshotScrollPolicy.delayUntilNextSample(elapsed:0.04),0.06,accuracy:0.0001)
        XCTAssertEqual(ScreenshotScrollPolicy.delayUntilNextSample(elapsed:0.2),0)
    }
    func testSlowCaptureSchedulesFreshFrameImmediatelyAfterCompletion() async throws {
        _ = NSApplication.shared
        let cg=try image(),screen=try XCTUnwrap(NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }).frame
        var times:[TimeInterval]=[]
        let done=expectation(description:"连续采集4帧")
        let controller=ScreenshotScrollWindowController(rect:screen,capture:{ _,_ in
            times.append(ProcessInfo.processInfo.systemUptime)
            // 模拟比100ms周期略慢的后端；不截图、不投递真实滚轮、不访问凭据。
            Thread.sleep(forTimeInterval:0.115)
            if times.count==4 {done.fulfill()}
            return cg
        },completed:{_ in})
        defer {controller.close()}
        // 仅调用本地处理函数标记滚动活跃；不向系统投递任何事件。
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:-10,wheel2:0,wheel3:0))
        controller.wheel(try XCTUnwrap(NSEvent(cgEvent:wheel)))
        controller.showWindow(nil)
        await fulfillment(of:[done],timeout:4)
        controller.close()
        let gaps=zip(times,times.dropFirst()).map {$1-$0}.sorted()
        XCTAssertGreaterThanOrEqual(gaps.count,3)
        XCTAssertLessThan(gaps[gaps.count/2],0.19,"115ms处理不能被固定timer网格变成200ms以上的帧间隔")
    }
    func testScreenEditorAndCaptureUseNonactivatingPanels() throws {
        _ = NSApplication.shared
        let cg=try image(),screen=try XCTUnwrap(NSScreen.screens.first).frame
        let frozen=FrozenSelectionContext(screenFrame:screen,localSelection:CGRect(x:20,y:20,width:100,height:80),image:cg)
        let editor=ScreenshotEditorWindowController(image:NSImage(cgImage:cg,size:CGSize(width:100,height:80)),context: .selection(frozen),preferences:ScreenshotToolPreferences())
        let capture=ScreenshotScrollWindowController(rect:CGRect(x:20,y:20,width:100,height:80),capture:{_,_ in cg},completed:{_ in})
        defer {editor.close();capture.close()}
        for owner in [try XCTUnwrap(editor.window),try XCTUnwrap(capture.window)] {
            XCTAssertTrue(owner.styleMask.contains(.nonactivatingPanel))
            XCTAssertFalse(owner.canBecomeMain,"覆盖层不能成为main并带起设置窗口")
            for child in owner.childWindows ?? [] {XCTAssertTrue(child.styleMask.contains(.nonactivatingPanel))}
        }
    }
    func testShowingPassiveCaptureDoesNotPromoteOrdinaryWindow() async throws {
        _ = NSApplication.shared
        let cg=try image()
        let settings=NSWindow(contentRect:CGRect(x:0,y:0,width:200,height:100),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        settings.isReleasedWhenClosed=false
        var mainEvents=0,activeEvents=0
        let mainObserver=NotificationCenter.default.addObserver(forName:NSWindow.didBecomeMainNotification,object:settings,queue:.main){_ in mainEvents+=1}
        let activeObserver=NotificationCenter.default.addObserver(forName:NSApplication.didBecomeActiveNotification,object:NSApp,queue:.main){_ in activeEvents+=1}
        defer {NotificationCenter.default.removeObserver(mainObserver);NotificationCenter.default.removeObserver(activeObserver);settings.close()}
        let controller=ScreenshotScrollWindowController(rect:CGRect(x:100,y:100,width:100,height:80),capture:{_,_ in cg},completed:{_ in})
        defer {controller.close()}
        ScreenshotAuxiliaryWindows.show(controller,activateApplication:false)
        for _ in 0..<10 {await Task.yield()}
        XCTAssertEqual(mainEvents,0)
        XCTAssertEqual(activeEvents,0)
        controller.close()
    }
}
