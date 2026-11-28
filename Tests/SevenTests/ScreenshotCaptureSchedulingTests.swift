import AppKit
import XCTest
@testable import Seven

@MainActor final class ScreenshotCaptureSchedulingTests: XCTestCase {
    private func image() throws -> CGImage {
        let context=try XCTUnwrap(CGContext(data:nil,width:100,height:80,bitsPerComponent:8,bytesPerRow:400,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
    func testCadenceDoesNotWaitAnotherIntervalAfterSlowCapture() {
        let interval = ScreenshotScrollPolicy.sampleInterval
        XCTAssertEqual(ScreenshotScrollPolicy.delayUntilNextSample(elapsed: interval + 0.008), 0)
        XCTAssertEqual(ScreenshotScrollPolicy.delayUntilNextSample(elapsed: interval / 2), interval / 2, accuracy: 0.0001)
        XCTAssertEqual(ScreenshotScrollPolicy.delayUntilNextSample(elapsed: interval * 2), 0)
    }
    func testSlowCaptureSchedulesFreshFrameImmediatelyAfterCompletion() async throws {
        _ = NSApplication.shared
        let cg=try image(),screen=try XCTUnwrap(NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }).frame
        var times:[TimeInterval]=[]
        let done=expectation(description:"连续采集4帧")
        let controller=ScreenshotScrollWindowController(rect:screen,capture:{ _,_ in
            times.append(ProcessInfo.processInfo.systemUptime)
            // Simulates a backend slightly slower than the 100ms interval; performs no capture, posts no real scroll events, and touches no credentials.
            Thread.sleep(forTimeInterval:0.115)
            if times.count==4 {done.fulfill()}
            return cg
        },completed:{_ in})
        defer {controller.close()}
        // Calls only the local handler to mark scrolling active; posts no events to the system.
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:-10,wheel2:0,wheel3:0))
        controller.wheel(try XCTUnwrap(NSEvent(cgEvent:wheel)))
        controller.showWindow(nil)
        await fulfillment(of:[done],timeout:4)
        controller.close()
        let gaps=zip(times,times.dropFirst()).map {$1-$0}.sorted()
        XCTAssertGreaterThanOrEqual(gaps.count,3)
        XCTAssertLessThan(gaps[gaps.count/2],0.19,"115ms处理不能被固定timer网格变成200ms以上的帧间隔")
    }
    func testScreenEditorAndCaptureCannotBecomeMainWindows() throws {
        _ = NSApplication.shared
        let cg=try image(),screen=try XCTUnwrap(NSScreen.screens.first).frame
        let frozen=FrozenSelectionContext(screenFrame:screen,localSelection:CGRect(x:20,y:20,width:100,height:80),image:cg)
        let editor=ScreenshotEditorWindowController(image:NSImage(cgImage:cg,size:CGSize(width:100,height:80)),context: .selection(frozen),preferences:ScreenshotToolPreferences())
        let capture=ScreenshotScrollWindowController(rect:CGRect(x:20,y:20,width:100,height:80),capture:{_,_ in cg},completed:{_ in})
        defer {editor.close();capture.close()}
        for owner in [try XCTUnwrap(editor.window),try XCTUnwrap(capture.window)] {
            XCTAssertFalse(owner.canBecomeMain,"覆盖层不能成为main并带起设置窗口")
        }
    }
    func testShowingPassiveCaptureOrEditorDoesNotPromoteOrdinaryWindow() async throws {
        _ = NSApplication.shared
        let cg=try image()
        let settings=NSWindow(contentRect:CGRect(x:0,y:0,width:200,height:100),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        settings.isReleasedWhenClosed=false
        var mainEvents=0,activeEvents=0
        let mainObserver=NotificationCenter.default.addObserver(forName:NSWindow.didBecomeMainNotification,object:settings,queue:.main){_ in mainEvents+=1}
        let activeObserver=NotificationCenter.default.addObserver(forName:NSApplication.didBecomeActiveNotification,object:NSApp,queue:.main){_ in activeEvents+=1}
        defer {NotificationCenter.default.removeObserver(mainObserver);NotificationCenter.default.removeObserver(activeObserver);settings.close()}
        let capture = ScreenshotScrollWindowController(rect: CGRect(x: 100, y: 100, width: 100, height: 80),
            capture: { _, _ in cg }, completed: { _ in })
        let editor = makeScreenshotEditorForTesting(image: NSImage(cgImage: cg, size: CGSize(width: 100, height: 80)),
            preferences: ScreenshotToolPreferences())
        let controllers: [NSWindowController] = [capture, editor]
        for controller in controllers {
            ScreenshotAuxiliaryWindows.show(controller, activateApplication: false)
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(mainEvents, 0)
            XCTAssertEqual(activeEvents, 0)
            controller.close()
        }
    }
}
