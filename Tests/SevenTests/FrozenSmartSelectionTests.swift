import AppKit
import XCTest
@testable import Seven

private actor SmartSelectionMock: FrozenSmartSelecting {
    var calls: [CGPoint] = []
    var queriedWindows: [CGWindowID] = []
    var result: CGRect?
    var pausesFirst: Bool
    var parents: [FrozenSmartRegion] = []
    var siblings: [FrozenSmartRegion] = []
    private var pending: CheckedContinuation<CGRect?, Never>?
    init(result: CGRect?, pausesFirst: Bool = false) { self.result = result; self.pausesFirst = pausesFirst }
    func regions(at point: CGPoint, in window: FrozenWindowCandidate, geometry: FrozenSmartGeometry) async -> FrozenSmartSelectionResult {
        calls.append(point); queriedWindows.append(window.id)
        if pausesFirst {
            pausesFirst = false
            let frame = await withCheckedContinuation { pending = $0 }
            return FrozenSmartSelectionResult(ancestry: (frame.map { [FrozenSmartRegion(role: "AXButton", frame: $0)] } ?? []) + parents, siblings: siblings)
        }
        return FrozenSmartSelectionResult(ancestry: (result.map { [FrozenSmartRegion(role: "AXButton", frame: $0)] } ?? []) + parents, siblings: siblings)
    }
    func release() { pending?.resume(returning: result); pending = nil }
    func pauseNext(returning result: CGRect?) { self.result = result; pausesFirst = true }
    func setParents(_ regions: [FrozenSmartRegion]) { parents = regions }
    func setSiblings(_ regions: [FrozenSmartRegion]) { siblings = regions }
}

@MainActor final class FrozenSmartSelectionTests: XCTestCase {
    private let windowRect = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let button = CGRect(x: 300, y: 300, width: 100, height: 40)
    private func view(_ mock: SmartSelectionMock, enabled: Bool = true, radius: CGFloat = 0, scale: Int = 1,
                      toggle: @escaping (FrozenWindowCandidate) -> Void = { _ in },
                      complete: @escaping (CGRect?, FrozenWindowCandidate?) -> Void) throws -> FrozenSelectionView {
        let context = try XCTUnwrap(CGContext(data: nil, width: 800 * scale, height: 600 * scale, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(windowRect)
        let image = try XCTUnwrap(context.makeImage())
        return FrozenSelectionView(frame: windowRect, image: image, screenFrame: windowRect,
            candidates: [.init(id: 10, frame: windowRect, ownerPID: 7)], smartSelectionEnabled: enabled,
            smartSelector: mock, primaryScreenTop: 600, outputCornerRadius: radius, fullScreen: {}, previousArea: {}, toggleWindow: toggle, complete: complete)
    }
    private func event(_ type: NSEvent.EventType, at point: CGPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    private func settle(_ mock: SmartSelectionMock, calls: Int = 1) async throws {
        for _ in 0..<200 {
            if await mock.calls.count >= calls { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let count = await mock.calls.count
        XCTAssertGreaterThanOrEqual(count, calls)
        for _ in 0..<10 { await Task.yield() }
    }
    func testSettingDefaultsOnAndPersistsOffAndOn() throws {
        let name = "SmartSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ScreenshotToolPreferences(defaults: defaults)
        XCTAssertTrue(preferences.smartSelectionEnabled)
        preferences.smartSelectionEnabled = false
        XCTAssertFalse(ScreenshotToolPreferences(defaults: defaults).smartSelectionEnabled)
        preferences.smartSelectionEnabled = true
        XCTAssertTrue(ScreenshotToolPreferences(defaults: defaults).smartSelectionEnabled)
        let memory = ScreenshotToolPreferences(); memory.smartSelectionEnabled = false
        XCTAssertFalse(memory.smartSelectionEnabled)
    }
    func testControlOwnsItsLabelButStandaloneTextAndViewportClippingArePreserved() {
        let panel = CGRect(x: 200, y: 200, width: 300, height: 250)
        let ancestry = [FrozenSmartRegion(role: "AXStaticText", frame: CGRect(x: 320, y: 310, width: 40, height: 15)),
            FrozenSmartRegion(role: "AXButton", frame: button), FrozenSmartRegion(role: "AXGroup", frame: panel)]
        XCTAssertEqual(FrozenSmartRegion.selection(at: CGPoint(x: 330, y: 315), in: windowRect, ancestry: ancestry), button)
        for role in ["AXTextField", "AXTextArea", "AXImage", "AXScrollArea", "AXGroup"] {
            XCTAssertEqual(FrozenSmartRegion.selection(at: CGPoint(x: 330, y: 315), in: windowRect,
                ancestry: [.init(role: role, frame: panel)]), panel)
        }
        let viewport = CGRect(x: 330, y: 300, width: 200, height: 100)
        XCTAssertEqual(FrozenSmartRegion.selection(at: CGPoint(x: 350, y: 315), in: windowRect,
            ancestry: [.init(role: "AXImage", frame: button), .init(role: "AXScrollArea", frame: viewport)]), button.intersection(viewport))
        XCTAssertEqual(FrozenSmartRegion.selection(at:CGPoint(x:330,y:315),in:windowRect,
            ancestry:[.init(role:"AXStaticText",frame:button),.init(role:"AXWindow",frame:windowRect)]),button)
    }
    func testClickingElementCropsRegionRatherThanCapturingWholeWindow() async throws {
        let mock = SmartSelectionMock(result: button)
        var rect: CGRect?, window: FrozenWindowCandidate?
        let selection = try view(mock) { rect = $0; window = $1 }
        let point = CGPoint(x: 350, y: 320)
        selection.refreshHover(at: point); try await settle(mock)
        selection.mouseDown(with: try event(.leftMouseDown, at: point))
        selection.mouseUp(with: try event(.leftMouseUp, at: point))
        XCTAssertEqual(rect, button); XCTAssertNil(window)
    }
    func testUnavailableElementFallsBackToWindow() async throws {
        let mock = SmartSelectionMock(result: nil)
        var rect: CGRect?, window: FrozenWindowCandidate?
        let selection = try view(mock) { rect = $0; window = $1 }
        let point = CGPoint(x: 350, y: 320)
        selection.refreshHover(at: point); try await settle(mock)
        selection.mouseDown(with: try event(.leftMouseDown, at: point)); selection.mouseUp(with: try event(.leftMouseUp, at: point))
        XCTAssertNil(rect); XCTAssertEqual(window?.id, 10)
    }
    func testRetinaContinuousRowsReuseKnownSiblingWithoutIntermediateParentOrExtraQuery() async throws {
        let upper = CGRect(x: 300, y: 455, width: 100, height: 36)
        let lower = CGRect(x: 300, y: 419, width: 100, height: 36)
        let mock = SmartSelectionMock(result: upper)
        await mock.setSiblings([.init(role: "AXButton", frame: lower)])
        var result: CGRect?
        let selection = try view(mock, scale: 2) { result = $0; XCTAssertNil($1) }
        selection.refreshHover(at: CGPoint(x: 350.66, y: 455.2)); try await settle(mock)
        XCTAssertEqual(selection.selection, upper)
        for y: CGFloat in [454.98828125, 454.76171875, 454.55] {
            selection.refreshHover(at: CGPoint(x: 350.66, y: y))
            XCTAssertEqual(selection.selection, lower)
        }
        selection.refreshHover(at: CGPoint(x: 350.66, y: 455.0390625))
        XCTAssertEqual(selection.selection, upper)
        selection.refreshHover(at: CGPoint(x: 350.66, y: 454.76171875))
        XCTAssertEqual(selection.selection, lower)
        let calls = await mock.calls.count
        XCTAssertEqual(calls, 1)
        let point = CGPoint(x: 350.66, y: 454.76171875)
        selection.mouseDown(with: try event(.leftMouseDown, at: point)); selection.mouseUp(with: try event(.leftMouseUp, at: point))
        XCTAssertEqual(result, lower)
    }
    func testParagraphSiblingCacheDoesNotFlashToWindowOrAcceptLatePreviousParagraph() async throws {
        let first=CGRect(x:200,y:360,width:300,height:32),second=CGRect(x:200,y:328,width:300,height:32)
        let parent=FrozenSmartRegion(role:"AXGroup",frame:CGRect(x:180,y:200,width:400,height:250))
        let mock=SmartSelectionMock(result:nil)
        await mock.setParents([.init(role:"AXGroup",frame:first,isTextBlock:true),parent])
        await mock.setSiblings([.init(role:"AXGroup",frame:second,isTextBlock:true)])
        var captured:CGRect?
        let selection=try view(mock,scale:2) {captured=$0;XCTAssertNil($1)}
        selection.refreshHover(at:CGPoint(x:250,y:375));try await settle(mock)
        XCTAssertEqual(selection.selection,first)
        await mock.pauseNext(returning:nil)
        selection.refreshHover(at:CGPoint(x:250,y:359.75))
        XCTAssertEqual(selection.selection,second)
        for _ in 0..<10 {await Task.yield()}
        selection.refreshHover(at:CGPoint(x:250,y:360.25));XCTAssertEqual(selection.selection,first)
        selection.refreshHover(at:CGPoint(x:250,y:359.75));XCTAssertEqual(selection.selection,second)
        await mock.release();for _ in 0..<15 {await Task.yield()}
        XCTAssertEqual(selection.selection,second)
        let point=CGPoint(x:250,y:344)
        selection.mouseDown(with:try event(.leftMouseDown,at:point));selection.mouseUp(with:try event(.leftMouseUp,at:point))
        XCTAssertEqual(captured,second)
    }
    func testDisabledSmartSelectionStillHoversAndClicksWholeWindowWithoutElementQuery() async throws {
        let mock=SmartSelectionMock(result:button)
        var captured:FrozenWindowCandidate?,rect:CGRect?
        let selection=try view(mock,enabled:false) {rect=$0;captured=$1}
        let point=CGPoint(x:350,y:320)
        selection.refreshHover(at:point)
        XCTAssertEqual(selection.selection,windowRect)
        selection.mouseDown(with:try event(.leftMouseDown,at:point))
        selection.mouseUp(with:try event(.leftMouseUp,at:point))
        XCTAssertEqual(captured?.id,10);XCTAssertNil(rect)
        let count=await mock.calls.count;XCTAssertEqual(count,0)
        let manual=try view(mock,enabled:false) {rect=$0;captured=$1}
        manual.mouseDown(with:try event(.leftMouseDown,at:point))
        manual.mouseDragged(with:try event(.leftMouseDragged,at:CGPoint(x:450,y:400)))
        manual.mouseUp(with:try event(.leftMouseUp,at:CGPoint(x:450,y:400)))
        XCTAssertNil(captured);XCTAssertEqual(rect,CGRect(x:350,y:320,width:100,height:80))
    }
    func testDisabledSkipsElementQueryButCommandStillSelectsWindows() async throws {
        let mock = SmartSelectionMock(result: button)
        var toggled: CGWindowID?, result: CGRect?
        let selection = try view(mock, enabled: false, toggle: { toggled = $0.id }) { result = $0; XCTAssertNil($1) }
        let point = CGPoint(x: 350, y: 320)
        selection.refreshHover(at: point)
        selection.mouseDown(with: try event(.leftMouseDown, at: point, flags: .command))
        selection.mouseUp(with: try event(.leftMouseUp, at: point, flags: .command))
        XCTAssertEqual(toggled, 10); XCTAssertNil(result)
        let calls = await mock.calls.count; XCTAssertEqual(calls, 0)
        selection.cancelSmartSelection()
    }
    func testDraggingOverridesElementAndStaleQueryCannotChangeManualRegion() async throws {
        let mock = SmartSelectionMock(result: button, pausesFirst: true)
        var rect: CGRect?, window: FrozenWindowCandidate?
        let selection = try view(mock) { rect = $0; window = $1 }
        let start = CGPoint(x: 350, y: 320), end = CGPoint(x: 550, y: 460)
        selection.refreshHover(at: start); try await settle(mock)
        selection.mouseDown(with: try event(.leftMouseDown, at: start))
        selection.mouseDragged(with: try event(.leftMouseDragged, at: end))
        await mock.release(); for _ in 0..<10 { await Task.yield() }
        selection.mouseUp(with: try event(.leftMouseUp, at: end))
        XCTAssertEqual(rect, CGRect(x: 350, y: 320, width: 200, height: 140)); XCTAssertNil(window)
    }
    func testOnePendingQueryFollowsLatestMouseAndDoesNotApplyOldResponse() async throws {
        let mock = SmartSelectionMock(result: button, pausesFirst: true)
        var rect: CGRect?, window: FrozenWindowCandidate?
        let selection = try view(mock) { rect = $0; window = $1 }
        selection.refreshHover(at: CGPoint(x: 350, y: 320)); try await settle(mock)
        let point = CGPoint(x: 600, y: 500)
        for _ in 0..<20 { selection.refreshHover(at: point) }
        let calls = await mock.calls.count; XCTAssertEqual(calls, 1)
        await mock.release(); try await settle(mock, calls: 2)
        selection.mouseDown(with: try event(.leftMouseDown, at: point)); selection.mouseUp(with: try event(.leftMouseUp, at: point))
        XCTAssertNil(rect); XCTAssertEqual(window?.id, 10)
    }
    func testCancelPreventsPendingResultAndFurtherQueries() async throws {
        let mock = SmartSelectionMock(result: button, pausesFirst: true)
        let selection = try view(mock) { _, _ in XCTFail("取消后不应提交截图") }
        selection.refreshHover(at: CGPoint(x: 350, y: 320)); try await settle(mock)
        selection.cancelSmartSelection(); await mock.release()
        selection.refreshHover(at: CGPoint(x: 600, y: 500))
        for _ in 0..<10 { await Task.yield() }
        let calls = await mock.calls.count; XCTAssertEqual(calls, 1)
    }

    func testLateQueryCanUseParentUnderCurrentPointerWithoutSelectingDepartedControl() async throws {
        let mock = SmartSelectionMock(result: button, pausesFirst: true)
        let panel = CGRect(x: 200, y: 200, width: 300, height: 250)
        await mock.setParents([.init(role: "AXGroup", frame: panel)])
        var result: CGRect?
        let selection = try view(mock) { result = $0; XCTAssertNil($1) }
        selection.refreshHover(at: CGPoint(x: 350, y: 320)); try await settle(mock)
        let point = CGPoint(x: 250, y: 250)
        selection.refreshHover(at: point)
        await mock.release(); try await settle(mock, calls: 2)
        XCTAssertEqual(selection.selection, panel)
        selection.mouseDown(with: try event(.leftMouseDown, at: point))
        selection.mouseUp(with: try event(.leftMouseUp, at: point))
        XCTAssertEqual(result, panel)
        XCTAssertNotEqual(result, button)
    }

    func testMovingBetweenElementsDoesNotFlashBackToWholeWindow() async throws {
        let mock = SmartSelectionMock(result: button)
        let selection = try view(mock, radius: 20) { _, _ in }
        func cornerBrightness() throws -> CGFloat {
            let bitmap = try XCTUnwrap(selection.bitmapImageRepForCachingDisplay(in: selection.bounds))
            selection.cacheDisplay(in: selection.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.colorAt(x: Int(305 * CGFloat(bitmap.pixelsWide) / 800),
                y: Int(295 * CGFloat(bitmap.pixelsHigh) / 600))?.usingColorSpace(.deviceRGB)).redComponent
        }
        selection.refreshHover(at: CGPoint(x: 350, y: 320)); try await settle(mock)
        XCTAssertEqual(selection.selection, button)
        let roundedCorner = try cornerBrightness()
        XCTAssertLessThan(roundedCorner, 0.95)
        let next = CGRect(x: 500, y: 300, width: 100, height: 40)
        await mock.pauseNext(returning: next)
        selection.refreshHover(at: CGPoint(x: 550, y: 320)); try await settle(mock, calls: 2)
        XCTAssertEqual(selection.selection, button, "等待新命中时不能先放大到整个窗口")
        XCTAssertEqual(try cornerBrightness(), roundedCorner, accuracy: 0.001, "等待期间圆角和蒙层也应保持一致")
        await mock.release(); for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(selection.selection, next)
        selection.refreshHover(at: CGPoint(x: 551, y: 320))
        for _ in 0..<10 { await Task.yield() }
        let count = await mock.calls.count
        XCTAssertEqual(count, 2, "完整终端控件内应复用，不重复访问系统")
        XCTAssertEqual(selection.selection, next)
        selection.cancelSmartSelection()
    }

    func testClickWhileNewHitIsPendingCannotCapturePreviousElement() async throws {
        let mock = SmartSelectionMock(result: button)
        var rect: CGRect?, window: FrozenWindowCandidate?
        let selection = try view(mock) { rect = $0; window = $1 }
        selection.refreshHover(at: CGPoint(x: 350, y: 320)); try await settle(mock)
        await mock.pauseNext(returning: CGRect(x: 500, y: 300, width: 100, height: 40))
        let point = CGPoint(x: 550, y: 320)
        selection.refreshHover(at: point); try await settle(mock, calls: 2)
        selection.mouseDown(with: try event(.leftMouseDown, at: point))
        selection.mouseUp(with: try event(.leftMouseUp, at: point))
        XCTAssertNil(rect); XCTAssertEqual(window?.id, 10)
        await mock.release()
    }
}


extension FrozenSmartSelectionTests {
    func testPendingWindowAQueryStartsExactlyOneQueryForStationaryPointerInWindowB() async throws {
        let targetB = CGRect(x: 500, y: 100, width: 120, height: 40)
        let mock = SmartSelectionMock(result: targetB, pausesFirst: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let selection = FrozenSelectionView(frame: windowRect, image: try XCTUnwrap(context.makeImage()), screenFrame: windowRect,
            candidates: [.init(id: 11, frame: CGRect(x: 0, y: 0, width: 350, height: 600), ownerPID: 7),
                         .init(id: 22, frame: CGRect(x: 450, y: 0, width: 350, height: 600), ownerPID: 8)],
            smartSelector: mock, fullScreen: {}, previousArea: {}) { _, _ in }
        defer { selection.cancelSmartSelection() }
        selection.refreshHover(at: CGPoint(x: 150, y: 120))
        try await settle(mock)
        selection.refreshHover(at: CGPoint(x: 550, y: 120)) // B上停住，不再制造mouseMoved事件。
        let pending = await mock.queriedWindows
        XCTAssertEqual(pending, [11])
        await mock.release()
        try await settle(mock, calls: 2)
        let windows = await mock.queriedWindows
        XCTAssertEqual(windows, [11, 22])
        XCTAssertEqual(selection.selection, targetB)
        try await Task.sleep(for: .milliseconds(30))
        let settled = await mock.queriedWindows
        XCTAssertEqual(settled, [11, 22], "补查一次即结束，不得循环查询或新增定时器")
    }
}

extension FrozenSmartSelectionTests {
    private func nativeGeometry(for window: NSWindow) -> FrozenSmartGeometry {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800).union(window.frame)
        return FrozenSmartGeometry(screenFrame: bounds, pixelSize: bounds.size, primaryScreenTop: bounds.maxY)
    }

    func testOwnWindowSelectionDoesNotSynchronouslyEnterAccessibilityCallbacks() throws {
        _ = NSApplication.shared
        let window = AccessibilityTrapWindow(contentRect: CGRect(x: 100, y: 100, width: 400, height: 300),
                                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = AccessibilityTrapView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let anchor = SettingsSmartSelectionAnchor(role: "AXButton")
        anchor.frame = CGRect(x: 40, y: 100, width: 120, height: 28)
        content.addSubview(anchor); window.contentView = content
        defer { window.close() }
        let geometry = nativeGeometry(for: window)
        let expected = geometry.rect(window.convertToScreen(anchor.convert(anchor.bounds, to: nil)))
        let point = geometry.point(CGPoint(x: expected.midX, y: expected.midY))
        let candidate = FrozenWindowCandidate(id: CGWindowID(window.windowNumber), frame: window.frame,
                                            ownerPID: ProcessInfo.processInfo.processIdentifier)
        window.hitReads = 0; content.reads = 0
        let result = FrozenNativeSmartSelection.query(at: point, in: candidate, geometry: geometry)
        XCTAssertEqual(window.hitReads, 0, "自身截图不能进入同步 AX hit-test，SwiftUI 回调卡住时外层时限无法中断")
        XCTAssertEqual(content.reads, 0, "自身截图应读取布局几何，不能同步遍历 SwiftUI 虚拟 AX 树")
        XCTAssertEqual(FrozenSmartRegion.selection(at: point, in: candidate.frame, ancestry: result.ancestry), expected)
    }

    func testOwnContainerAndMissingWindowNeverFallBackToSystemAX() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        defer { window.close() }
        let spy = RemoteSelectionSpy()
        let selector = SystemFrozenSmartSelection(remote: spy)
        let geometry = nativeGeometry(for: window)
        let pid = ProcessInfo.processInfo.processIdentifier
        for id in [CGWindowID(window.windowNumber), CGWindowID.max] {
            let candidate = FrozenWindowCandidate(id: id, frame: window.frame, ownerPID: pid)
            _ = await selector.regions(at: CGPoint(x: 150, y: 150), in: candidate, geometry: geometry)
        }
        let ownCalls = await spy.calls
        XCTAssertEqual(ownCalls, 0, "自身容器/失效窗口不能对自己的 PID 开启 AX 模式或补查虚拟树")
        let external = FrozenWindowCandidate(id: 1, frame: window.frame, ownerPID: pid + 1)
        _ = await selector.regions(at: CGPoint(x: 150, y: 150), in: external, geometry: geometry)
        let externalCalls = await spy.calls
        XCTAssertEqual(externalCalls, 1, "其他应用仍使用既有后台系统 AX 路径")
    }
}

@MainActor private final class AccessibilityTrapWindow: NSWindow {
    var hitReads = 0
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        hitReads += 1
        return contentView
    }
}

@MainActor private final class AccessibilityTrapView: NSView {
    var reads = 0
    override func accessibilityChildren() -> [Any]? { reads += 1; return [] }
    override func accessibilityRole() -> NSAccessibility.Role? { reads += 1; return .group }
    override func accessibilityFrame() -> NSRect { reads += 1; return .zero }
    override func accessibilityParent() -> Any? { reads += 1; return window }
}

private actor RemoteSelectionSpy: FrozenSmartSelecting {
    private(set) var calls = 0
    func regions(at point: CGPoint, in window: FrozenWindowCandidate, geometry: FrozenSmartGeometry) async -> FrozenSmartSelectionResult {
        calls += 1
        return FrozenSmartSelectionResult()
    }
}
