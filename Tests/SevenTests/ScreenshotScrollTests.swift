import AppKit
import CoreGraphics
import XCTest
@testable import Seven

@MainActor private final class ScrollEventMock: ScreenshotScrollEventMonitoring {
    var global: [UUID: (NSEvent.EventTypeMask, (NSEvent) -> Void)] = [:]
    var local: [UUID: (NSEvent.EventTypeMask, (NSEvent) -> NSEvent?)] = [:]
    var removed: [UUID] = []
    func addGlobal(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) -> Any? {
        let id = UUID(); global[id] = (mask, handler); return id
    }
    func addLocal(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        let id = UUID(); local[id] = (mask, handler); return id
    }
    func remove(_ monitor: Any) {
        guard let id = monitor as? UUID else { return }
        removed.append(id); global[id] = nil; local[id] = nil
    }
    func emitGlobal(_ event: NSEvent) {
        let mask = NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue)
        for (types, handler) in Array(global.values) where types.contains(mask) { handler(event) }
    }
}

final class ScreenshotScrollTests: XCTestCase {
    private func frame(offset: Int, height: Int = 80, width: Int = 100, top: Int = 0, bottom: Int = 0, bright: Bool = false, rowPeriod: Int? = nil, scrollbar: Bool = false) throws -> ScreenshotScrollFrame {
        var bytes = [UInt8]()
        for y in 0..<height {
            let original = y < top ? y : y >= height - bottom ? 900 + y : y + offset
            let absolute = rowPeriod.map { original % $0 } ?? original
            for x in 0..<width {
                // Each row has unique horizontal features without relying on natural language content or system screenshots.
                let mixed = (absolute &* 31 &+ x &* 67) ^ (absolute &* x &* 13)
                let value = bright ? 230 + abs(mixed % 20) : 20 + abs(mixed % 210)
                let byte = scrollbar && x >= width-3 && y >= 2 && y < height-2 ? UInt8(110) : UInt8(value)
                bytes += [byte, byte, byte, 255]
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try ScreenshotScrollFrame(image: image)
    }

    private func readyMatcher(initial: ScreenshotScrollFrame) -> ScreenshotScrollMatcher {
        var matcher = ScreenshotScrollMatcher(initial: initial)
        XCTAssertEqual(matcher.consume(initial), .unchanged)
        return matcher
    }

    @MainActor func testExternalEscapeWithoutToolbarFocusStopsCaptureAndRemovesMonitors() throws {
        let events = ScrollEventMock(), image = try frame(offset: 0).image
        var outputs = 0
        let controller = ScreenshotScrollWindowController(rect: CGRect(x: 100, y: 100, width: 100, height: 80),
            capture: { _, _ in image }, events: events, completed: { _ in outputs += 1 })
        defer { controller.close() }
        controller.showWindow(nil)
        let root = try XCTUnwrap(controller.window), panels = root.childWindows ?? []
        let original = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 80), styleMask: .titled, backing: .buffered, defer: false)
        original.isReleasedWhenClosed = false
        defer { original.close() }
        original.makeKeyAndOrderFront(nil)
        XCTAssertFalse(panels.contains { $0.isKeyWindow })
        XCTAssertTrue(controller.isCapturing)
        let installed = Set(events.global.keys).union(events.local.keys)
        XCTAssertFalse(installed.isEmpty)
        let reset = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15))
        events.emitGlobal(reset)
        XCTAssertTrue(controller.isCapturing)
        XCTAssertEqual(Set(events.global.keys).union(events.local.keys), installed, "原应用的工具键不能改变采集输入会话")
        let modifiedEscape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        events.emitGlobal(modifiedEscape)
        XCTAssertTrue(controller.isCapturing, "不能拦截原应用的带修饰键组合")
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        events.emitGlobal(escape) // Simulates the original app holding focus without sending local or real global keyboard events.
        XCTAssertFalse(controller.isCapturing)
        XCTAssertFalse(root.isVisible)
        XCTAssertTrue(panels.allSatisfy { !$0.isVisible })
        XCTAssertTrue(events.global.isEmpty); XCTAssertTrue(events.local.isEmpty)
        XCTAssertEqual(Set(events.removed), installed)
        XCTAssertEqual(events.removed.count, installed.count)
        XCTAssertNil(controller.sampling); XCTAssertEqual(outputs, 0)
        controller.close()
        XCTAssertEqual(events.removed.count, installed.count, "重复关闭不能重复注销")
    }

    func testFirstScrollingFrameIsNotDropped() throws {
        let first = try frame(offset: 0)
        var matcher = ScreenshotScrollMatcher(initial: first)
        XCTAssertEqual(matcher.consume(try frame(offset: 8)), .addedPixels(8))
        XCTAssertEqual(matcher.acceptedFrames, 2)
        XCTAssertEqual(matcher.consume(try frame(offset: 16)), .addedPixels(8))
        XCTAssertEqual(try ScreenshotScrollFrame(image: XCTUnwrap(matcher.image)).pixels,
                       try frame(offset: 0, height: 96).pixels)
    }

    func testTranslatedRowsMatchAndProducePixelExactImage() throws {
        let first = try frame(offset: 0)
        let next = try frame(offset: 8)
        var matcher = readyMatcher(initial: first)
        XCTAssertEqual(matcher.consume(next), .addedPixels(8))
        XCTAssertEqual(matcher.addedHeight, 8)
        let rendered = try ScreenshotScrollFrame(image: XCTUnwrap(matcher.image))
        XCTAssertEqual(rendered.height, 88)
        let expected = try frame(offset: 0, height: 88)
        XCTAssertEqual(rendered.pixels, expected.pixels)
    }

    func testRepeatedCommitsMergeContributionsWithoutLosingRows() throws {
        let first = try frame(offset: 0)
        var matcher = readyMatcher(initial: first)
        for offset in [8, 16, 24] {
            XCTAssertEqual(matcher.consume(try frame(offset: offset)), .addedPixels(8))
        }
        let image = try ScreenshotScrollFrame(image: XCTUnwrap(matcher.image))
        XCTAssertEqual(image.height, 104)
        XCTAssertEqual(image.pixels, try frame(offset: 0, height: 104).pixels)
    }

    func testUpwardCapturePrependsAndRevisitingDoesNotDuplicateRows() throws {
        var matcher = readyMatcher(initial: try frame(offset: 0))
        XCTAssertEqual(matcher.consume(try frame(offset: -8), directionHint: -1), .addedPixels(8))
        XCTAssertEqual(matcher.position,-8); XCTAssertEqual(matcher.lower,-8)
        XCTAssertEqual(matcher.consume(try frame(offset: 0), directionHint: 1), .movedWithinRange)
        XCTAssertEqual(matcher.consume(try frame(offset: 16), directionHint: 1), .addedPixels(16))
        XCTAssertEqual(matcher.consume(try frame(offset: -4), directionHint: -1), .movedWithinRange)
        XCTAssertEqual(matcher.outputHeight,104)
        XCTAssertEqual(try ScreenshotScrollFrame(image:XCTUnwrap(matcher.image)).pixels,try frame(offset:-8,height:104).pixels)
    }

    func testJumpAcrossCollectedContentRelocatesWithoutDuplicatingPixels() throws {
        var matcher=readyMatcher(initial:try frame(offset:0))
        for position in [30,60,90] {XCTAssertEqual(matcher.consume(try frame(offset:position),directionHint:1),.addedPixels(30))}
        let before=try ScreenshotScrollFrame(image:XCTUnwrap(matcher.image)).pixels
        XCTAssertEqual(matcher.consume(try frame(offset:10),directionHint:-1),.movedWithinRange)
        XCTAssertEqual(matcher.position,10)
        XCTAssertEqual(matcher.matchInfo.reference,.collectedViewport)
        XCTAssertEqual(try ScreenshotScrollFrame(image:XCTUnwrap(matcher.image)).pixels,before)
        XCTAssertEqual(matcher.consume(try frame(offset:70),directionHint:-1),.movedWithinRange)
        XCTAssertEqual(matcher.outputHeight,170)
    }

    func testRevisitingBothEndsAndExtendingAfterRelocationKeepsPixelExactOutput() throws {
        var matcher = readyMatcher(initial: try frame(offset: 0, top: 6, bottom: 5))
        for position in stride(from: 30, through: 300, by: 30) {
            XCTAssertEqual(matcher.consume(try frame(offset: position, top: 6, bottom: 5)), .addedPixels(30))
        }
        let before = try ScreenshotScrollFrame(image: XCTUnwrap(matcher.image)).pixels
        for position in [10, 290, 60, 240, 0, 300] {
            XCTAssertEqual(matcher.consume(try frame(offset: position, top: 6, bottom: 5)), .movedWithinRange)
            XCTAssertEqual(matcher.position, position)
            XCTAssertEqual(matcher.outputHeight, 380)
            XCTAssertEqual(try ScreenshotScrollFrame(image: XCTUnwrap(matcher.image)).pixels, before)
        }
        XCTAssertEqual(matcher.consume(try frame(offset: 320, top: 6, bottom: 5)), .addedPixels(20))
        XCTAssertEqual(matcher.consume(try frame(offset: 0, top: 6, bottom: 5)), .movedWithinRange)
        XCTAssertEqual(matcher.consume(try frame(offset: -20, top: 6, bottom: 5)), .addedPixels(20))
        XCTAssertEqual(matcher.outputHeight, 420)
    }

    func testSmallScrollStepsKeepInteriorReferencesAndLatestEndpoints() throws {
        var matcher = readyMatcher(initial: try frame(offset: 0))
        for position in stride(from: 8, through: 240, by: 8) {
            XCTAssertEqual(matcher.consume(try frame(offset: position)), .addedPixels(8))
        }
        XCTAssertGreaterThan(matcher.referenceCount, 5)
        for position in [0, 240, 80, 160, 0, 240] {
            XCTAssertEqual(matcher.consume(try frame(offset: position)), .movedWithinRange)
            XCTAssertEqual(matcher.position, position)
            XCTAssertEqual(matcher.outputHeight, 320)
        }
    }

    func testReferenceMemoryIsBoundedAndKeepsCollectedEndpoints() throws {
        var matcher = readyMatcher(initial: try frame(offset: 0))
        for position in stride(from: 30, through: 2400, by: 30) {
            XCTAssertEqual(matcher.consume(try frame(offset: position)), .addedPixels(30))
        }
        XCTAssertLessThanOrEqual(matcher.referenceCount, 64)
        XCTAssertEqual(matcher.consume(try frame(offset: 0)), .movedWithinRange)
        XCTAssertEqual(matcher.position, 0)
        XCTAssertEqual(matcher.consume(try frame(offset: 2400)), .movedWithinRange)
        XCTAssertEqual(matcher.position, 2400)
    }

    func testAlternatingDirectionsKeepFixedHeaderFooterOnceAndBodyContinuous() throws {
        let initial = try frame(offset:40,top:6,bottom:5)
        var matcher = readyMatcher(initial:initial)
        for position in [32,24,48,64,40] {
            let result = matcher.consume(try frame(offset:position,top:6,bottom:5),directionHint:position<40 ? -1:1)
            XCTAssertNotEqual(result,.noMatch)
        }
        XCTAssertEqual(matcher.outputHeight,120)
        let output = try ScreenshotScrollFrame(image:XCTUnwrap(matcher.image))
        let content = try frame(offset:24,height:120)
        let rowBytes = content.width*4
        let expected = Array(initial.pixels[..<(6*rowBytes)]) + Array(content.pixels[(6*rowBytes)..<(115*rowBytes)]) + Array(initial.pixels[(75*rowBytes)...])
        XCTAssertEqual(output.pixels,expected)
    }

    func testBrightContentUsesTheSameVerifiedMatchingAsOtherApplications() throws {
        let first = try frame(offset: 0, bright: true)
        var matcher = readyMatcher(initial: first)
        XCTAssertEqual(matcher.consume(try frame(offset: 8, bright: true)), .addedPixels(8))
    }

    func testLostOverlapPreservesPixelsAndRecoversAfterUserScrollsBack() throws {
        let first = try frame(offset: 0)
        var matcher = readyMatcher(initial: first)
        XCTAssertEqual(matcher.consume(try frame(offset: 8)), .addedPixels(8))
        let before = try XCTUnwrap(matcher.image)
        XCTAssertEqual(matcher.consume(try frame(offset: 500, bright: true)), .noMatch)
        XCTAssertEqual(matcher.outputHeight, 88)
        XCTAssertEqual(try ScreenshotScrollFrame(image: XCTUnwrap(matcher.image)).pixels, try ScreenshotScrollFrame(image: before).pixels)
        // The recovered frame is still ahead of the last successful frame; do not reject valid overlap solely due to upward wheel direction.
        XCTAssertEqual(matcher.consume(try frame(offset: 16)), .addedPixels(8))
        XCTAssertEqual(try ScreenshotScrollFrame(image: XCTUnwrap(matcher.image)).pixels, try frame(offset: 0, height: 96).pixels)
    }

    func testNoFeatureCannotTriggerAnInventedTenPixelAppend() throws {
        let first = try frame(offset: 0)
        var matcher = readyMatcher(initial: first)
        XCTAssertEqual(matcher.consume(try frame(offset: 8, bright: true)), .noMatch)
        XCTAssertEqual(matcher.consume(try frame(offset: 16)), .addedPixels(16))
        XCTAssertEqual(matcher.addedHeight, 16)
    }

    func testPixelBudgetStopsBeforeAllocatingAnOversizedOutput() throws {
        let first = try frame(offset: 0)
        var matcher = ScreenshotScrollMatcher(initial: first, maximumPixels: 8_500)
        XCTAssertEqual(matcher.consume(try frame(offset: 8)), .limitReached)
        XCTAssertEqual(matcher.outputHeight, 80)
        XCTAssertEqual(try ScreenshotScrollFrame(image: XCTUnwrap(matcher.image)).pixels, first.pixels)
    }

    func testFixedHeaderAndFooterAppearOnlyOnce() throws {
        let initial = try frame(offset: 0, top: 6, bottom: 5)
        var matcher = readyMatcher(initial: initial)
        for offset in [8, 16, 24, 32] {
            guard case .addedPixels = matcher.consume(try frame(offset: offset, top: 6, bottom: 5)) else {
                return XCTFail("固定头尾不能阻止正文拼接，offset=\(offset)")
            }
        }
        let output = try ScreenshotScrollFrame(image: XCTUnwrap(matcher.image))
        XCTAssertEqual(output.height, 112)
        let fullContent = try frame(offset: 0, height: 112)
        let rowBytes = output.width * 4
        let expected = Array(initial.pixels[..<(6 * rowBytes)])
            + Array(fullContent.pixels[(6 * rowBytes)..<(107 * rowBytes)])
            + Array(initial.pixels[(75 * rowBytes)...])
        XCTAssertEqual(output.pixels, expected)
    }

    func testRepeatingRowsAreValidatedAcrossTheWholeOverlap() throws {
        let first = try frame(offset: 0, rowPeriod: 10)
        var matcher = readyMatcher(initial: first)
        XCTAssertEqual(matcher.consume(try frame(offset: 4, rowPeriod: 10)), .addedPixels(4))
        XCTAssertEqual(matcher.acceptedFrames, 2)
        XCTAssertEqual(matcher.outputHeight, first.height + 4)
        XCTAssertEqual(try ScreenshotScrollFrame(image: XCTUnwrap(matcher.image)).pixels,
                       try frame(offset: 0, height: 84, rowPeriod: 10).pixels)
    }

    func testRetinaScaleMatchesPixelsAndPreviewHasSameAspect() throws {
        let first = try frame(offset: 0, height: 100, width: 120)
        var matcher = readyMatcher(initial: first)
        XCTAssertEqual(matcher.consume(try frame(offset: 12, height: 100, width: 120)), .addedPixels(12))
        XCTAssertEqual(matcher.outputHeight, 112)
        let preview = try XCTUnwrap(matcher.previewImage(maximumSize: CGSize(width:60,height:60)))
        XCTAssertEqual(preview.width, 60)
        XCTAssertEqual(preview.height, 56)
        XCTAssertEqual(try ScreenshotScrollFrame(image: XCTUnwrap(matcher.image)).pixels,
                       try frame(offset: 0, height: 112, width: 120).pixels)
    }

    func testChangedFrameSizeIsRejectedWithoutChangingOutput() throws {
        let first = try frame(offset: 0)
        var matcher = readyMatcher(initial: first)
        XCTAssertEqual(matcher.consume(try frame(offset: 8, width: 120)), .noMatch)
        XCTAssertEqual(try ScreenshotScrollFrame(image: XCTUnwrap(matcher.image)).pixels, first.pixels)
    }

    @MainActor func testCaptureUsesClickThroughBorderAndSeparateOutsidePreview() async throws {
        _ = NSApplication.shared
        let image = try frame(offset: 0).image
        let rect = CGRect(x: 100, y: 200, width: 400, height: 300)
        let controller = ScreenshotScrollWindowController(rect: rect, capture: { _, _ in image }, completed: { _ in })
        defer { controller.close() }
        let border = try XCTUnwrap(controller.window)
        XCTAssertFalse(border.hidesOnDeactivate, "在原应用滚动时边框不能消失")
        XCTAssertTrue(border.ignoresMouseEvents, "原应用必须仍能收到选区中的滚动")
        controller.sample(); await controller.sampling?.value
        let preview = try XCTUnwrap(previewScroller(in: controller).window)
        XCTAssertFalse(preview.frame.isEmpty)
        XCTAssertFalse(preview.frame.intersects(rect))
    }

    @MainActor func testPreviewViewportHidesOnUncertainLocationAndRestoresOnReturn() async throws {
        _ = NSApplication.shared
        var image = try frame(offset: 0).image
        let controller = ScreenshotScrollWindowController(rect: CGRect(x: 100, y: 100, width: 400, height: 300), capture: { _, _ in image }, completed: { _ in })
        defer { controller.close() }
        controller.sample(); await controller.sampling?.value
        let preview = try XCTUnwrap(previewScroller(in: controller).documentView as? ScreenshotScrollPreviewImage)
        XCTAssertEqual(preview.viewport, CGRect(x: 0, y: 0, width: 1, height: 1))
        for position in [30, 60, 90] {
            image = try frame(offset: position).image; controller.sample(); await controller.sampling?.value
        }
        XCTAssertEqual(try XCTUnwrap(preview.viewport).minY, 90.0/170, accuracy: 0.001)
        image = try frame(offset: 500, bright: true).image; controller.sample(); await controller.sampling?.value
        XCTAssertNil(preview.viewport)
        image = try frame(offset: 0).image; controller.sample(); await controller.sampling?.value
        XCTAssertEqual(try XCTUnwrap(preview.viewport).minY, 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(preview.viewportRect).height, preview.bounds.height * 80 / 170, accuracy: 0.001)
    }

    @MainActor func testFinishingConsumesFinalCaptureBeforeReturningImage() async throws {
        _ = NSApplication.shared
        let image = try frame(offset: 0).image
        var captures = 0
        let finished = expectation(description: "完成后交付最终长图")
        let controller = ScreenshotScrollWindowController(rect: CGRect(x: 0, y: 0, width: 100, height: 80), capture: { _, _ in
            captures += 1
            return image
        }) { output in
            XCTAssertEqual(output.size, CGSize(width: 100, height: 80))
            finished.fulfill()
        }
        defer { controller.close() }
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("editImage"), to: controller, from: nil))
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(captures, 2, "最终内容采样一次，背景另采一次，始终排除采集控件")
    }

    @MainActor func testFinishingWithoutAnyCapturedFrameShowsFailureAndKeepsCancelAvailable() async throws {
        _ = NSApplication.shared
        let delivered = expectation(description: "没有帧时不能交付空图")
        delivered.isInverted = true
        var captures = 0
        let controller = ScreenshotScrollWindowController(rect: CGRect(x: 0, y: 0, width: 100, height: 80), capture: { _, _ in
            captures += 1
            return nil
        }) { _ in delivered.fulfill() }
        defer { controller.close() }
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("editImage"), to: controller, from: nil))
        await fulfillment(of: [delivered], timeout: 0.1)
        let views = capturePanelViews(in: controller)
        XCTAssertEqual(try statusLabel(in: controller).stringValue, L10n.text("noScreenshotIsAvailableExitAndSelect"))
        let buttons = views.compactMap { $0 as? NSButton }
        let copy = try XCTUnwrap(buttons.first { $0.action == NSSelectorFromString("copyImage") })
        let cancel = try XCTUnwrap(buttons.first { $0.action == NSSelectorFromString("cancelCapture") })
        XCTAssertFalse(copy.isEnabled)
        XCTAssertTrue(cancel.isEnabled)
        let window = try XCTUnwrap(controller.window)
        window.orderFrontRegardless()
        XCTAssertTrue(window.isVisible)
        cancel.performClick(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(captures, 1)
    }

    @MainActor func testClosingWhileFinishingPreventsLateDelivery() async throws {
        _ = NSApplication.shared
        let image = try frame(offset: 0).image
        var captures = 0
        let delivered = expectation(description: "关闭后不再弹出编辑器")
        delivered.isInverted = true
        let controller = ScreenshotScrollWindowController(rect: CGRect(x: 0, y: 0, width: 100, height: 80), capture: { _, _ in
            captures += 1
            return image
        }) { _ in delivered.fulfill() }
        defer { controller.close() }
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("editImage"), to: controller, from: nil))
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        await fulfillment(of: [delivered], timeout: 0.1)
        XCTAssertEqual(captures, 0, "取消完成任务后不能再捕获屏幕")
    }

    func testStatusIsAnchoredTopLeftAndPreviewAvoidsBothPanels() throws {
        let screen = CGRect(x: -1200, y: 100, width: 1200, height: 900)
        let selection = CGRect(x: -1000, y: 300, width: 600, height: 450)
        let size = CGSize(width: 250, height: Design.ScreenshotEditor.sizeToolbarHeight)
        let status = ScreenshotScrollLayout.statusRect(size: size, selection: selection, screen: screen)
        XCTAssertEqual(status.minX, selection.minX)
        XCTAssertEqual(status.minY, selection.maxY + Design.Space.s)
        let topSelection = CGRect(x: -1000, y: 300, width: 600, height: 690)
        let inside = ScreenshotScrollLayout.statusRect(size: size, selection: topSelection, screen: screen)
        XCTAssertEqual(inside.maxY, topSelection.maxY - Design.Space.s)
        XCTAssertTrue(screen.contains(inside))
        let tool = CGRect(x: -700, y: 250, width: 300, height: 40)
        let space = try XCTUnwrap(ScreenshotScrollLayout.previewSpace(outside: selection, screen: screen, avoiding: tool, alsoAvoiding: status))
        XCTAssertFalse(space.intersects(status)); XCTAssertFalse(space.intersects(tool))
    }

    func testPreviewFitsOutsideSelectionOnOffsetDisplay() throws {
        let screen = CGRect(x: -1200, y: 300, width: 1200, height: 900)
        for region in [CGRect(x: -1100, y: 500, width: 700, height: 500), CGRect(x: -800, y: 500, width: 700, height: 500)] {
            let preview = try XCTUnwrap(ScreenshotScrollLayout.previewSpace(outside: region, screen: screen))
            XCTAssertTrue(screen.contains(preview)); XCTAssertFalse(region.intersects(preview))
        }
        let inside = try XCTUnwrap(ScreenshotScrollLayout.previewSpace(outside:screen,screen:screen))
        XCTAssertTrue(screen.contains(inside), "全屏选区没有外部空间时，预览贴入选区并限制在屏幕内")
    }

    @MainActor func testLongImageEditsCenteredInOverlayWithoutLosingOutputPixels() throws {
        _ = NSApplication.shared
        let cg = try frame(offset: 0, height: 1800, width: 200).image
        let image = NSImage(cgImage: cg, size: CGSize(width: 100, height: 900))
        let screen = CGRect(x: -1200, y: 300, width: 1200, height: 800)
        let editor = ScreenshotEditorWindowController(image: image, context: .centered(.init(screenFrame: screen, background: nil)), preferences: ScreenshotToolPreferences())
        defer { editor.close() }
        let window = try XCTUnwrap(editor.window)
        let canvas = try XCTUnwrap(window.contentView?.subviews.compactMap { $0 as? ScreenshotEditorCanvas }.first)
        XCTAssertEqual(window.frame, screen)
        XCTAssertEqual(canvas.frame.midX, screen.width/2, accuracy: 0.01)
        XCTAssertEqual(canvas.frame.midY, screen.height/2, accuracy: 0.01)
        XCTAssertLessThan(canvas.frame.height, screen.height)
        let output = try XCTUnwrap(canvas.renderedImage().cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(output.width, 200); XCTAssertEqual(output.height, 1800)
    }
    @MainActor func testResetReplacesAccumulatedImageAndThumbnailWithoutOldWrites() async throws {
        _ = NSApplication.shared
        var current = try frame(offset: 0).image
        let fresh = try frame(offset: 40, bright: true).image
        let done = expectation(description: "重置后交付当前新画面")
        let controller = ScreenshotScrollWindowController(rect: CGRect(x: 0, y: 0, width: 100, height: 80), capture: { _, _ in current }, captureBackground: { _, _ in nil }) { output in
            let image = output.cgImage(forProposedRect: nil, context: nil, hints: nil)
            XCTAssertEqual(try? ScreenshotScrollFrame(image: XCTUnwrap(image)).pixels, try? ScreenshotScrollFrame(image: fresh).pixels)
            done.fulfill()
        }
        defer { controller.close() }
        controller.sample(); await controller.sampling?.value
        current = try frame(offset: 8).image
        controller.sample(); await controller.sampling?.value
        let thumbnail = try XCTUnwrap(previewScroller(in: controller).documentView as? NSImageView)
        let previousImage = try XCTUnwrap(thumbnail.image)
        current = fresh
        controller.resetCapture(); await controller.sampling?.value
        let resetImage = try XCTUnwrap(thumbnail.image)
        XCTAssertFalse(resetImage === previousImage)
        XCTAssertEqual(resetImage.size.width / resetImage.size.height, CGFloat(fresh.width) / CGFloat(fresh.height), accuracy: 0.01)
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("editImage"), to: controller, from: nil))
        await fulfillment(of: [done], timeout: 2)
    }

    @MainActor func testReturningToExactLastGoodFrameClearsRecoveryMessage() async throws {
        _ = NSApplication.shared
        let first = try frame(offset: 0).image
        var current = first
        let controller = ScreenshotScrollWindowController(rect: CGRect(x: 0, y: 0, width: 100, height: 80), capture: { _, _ in current }, completed: { _ in })
        defer { controller.close() }
        controller.sample(); await controller.sampling?.value
        current = try frame(offset: 500, bright: true).image
        controller.sample(); await controller.sampling?.value
        let preview = try XCTUnwrap(previewScroller(in: controller).documentView as? ScreenshotScrollPreviewImage)
        let label = try statusLabel(in: controller)
        XCTAssertNil(preview.viewport)
        XCTAssertEqual(label.stringValue, L10n.text("findingTheOverlapYourCaptureIsSafe"))
        current = first; controller.sample(); await controller.sampling?.value
        XCTAssertNotNil(preview.viewport)
        XCTAssertEqual(label.stringValue, L10n.text("foundTheSeamYouCanContinueScrolling"))
    }
    func testFadingScrollbarDoesNotHideTheRealOverlapBelowStickyHeader() throws {
        let first = try frame(offset: 0, height: 160, width: 160, top: 32, bottom: 10)
        var matcher = ScreenshotScrollMatcher(initial: first)
        let next = try frame(offset: 12, height: 160, width: 160, top: 32, bottom: 10, scrollbar: true)
        XCTAssertEqual(matcher.consume(next), .addedPixels(12))
        XCTAssertEqual(matcher.outputHeight, 172)
    }

    func testPreviewRendersAtBackingPixelDimensionsInsteadOfEnlargingASmallBitmap() throws {
        let frame = try frame(offset: 0, height: 1800, width: 1000)
        let matcher = ScreenshotScrollMatcher(initial: frame)
        let preview = try XCTUnwrap(matcher.previewImage(maximumSize: CGSize(width: 400, height: 1280)))
        XCTAssertEqual(preview.width, 400)
        XCTAssertEqual(preview.height, 720, "200pt 宽的 Retina 预览应有400物理像素，不能先渲成200再放大")
    }

    func testPreviewChangesAspectAndStaysInsideEveryScreenEdgeAndAwayFromToolbar() throws {
        let screen = CGRect(x: -1400, y: -500, width: 1400, height: 900)
        let selections = [
            CGRect(x: -1380,y: -480,width: 800,height: 500),
            CGRect(x: -820,y: -480,width: 800,height: 500),
            CGRect(x: -1100,y: -150,width: 800,height: 500),
            CGRect(x: -1100,y: -480,width: 800,height: 500)
        ]
        for selection in selections {
            let toolbar = CGRect(x: selection.maxX-300,y: selection.minY-70,width: 300,height: 60)
            let space = try XCTUnwrap(ScreenshotScrollLayout.previewSpace(outside: selection, screen: screen, avoiding: toolbar))
            for size in [CGSize(width: 200,height: 100),CGSize(width: 200,height: 400),CGSize(width: 200,height: 3000)] {
                let panel = try XCTUnwrap(ScreenshotScrollLayout.previewRect(imageSize: size, within: space, beside: selection))
                XCTAssertTrue(screen.contains(panel)); XCTAssertFalse(selection.intersects(panel))
                XCTAssertFalse(toolbar.intersects(panel))
                let content = panel.insetBy(dx: Design.Space.s,dy: Design.Space.s)
                XCTAssertLessThanOrEqual(content.height,content.width*size.height/size.width+0.001)
            }
        }
        let selection = selections[0]
        let space = try XCTUnwrap(ScreenshotScrollLayout.previewSpace(outside: selection, screen: screen))
        let first = try XCTUnwrap(ScreenshotScrollLayout.previewRect(imageSize: CGSize(width: 200,height: 100),within:space,beside:selection))
        let longer = try XCTUnwrap(ScreenshotScrollLayout.previewRect(imageSize: CGSize(width: 200,height: 300),within:space,beside:selection))
        XCTAssertGreaterThan(longer.height,first.height)
        let tallest = try XCTUnwrap(ScreenshotScrollLayout.previewRect(imageSize: CGSize(width: 200,height: 3000),within:space,beside:selection))
        XCTAssertTrue(space.contains(tallest))
    }

    @MainActor func testSamplingPreservesFullScreenPreviewReadingPosition() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first).frame
        let tall = try frame(offset:0,height:2400,width:100).image
        let controller = ScreenshotScrollWindowController(rect:screen,capture:{_,_ in tall},completed:{_ in})
        defer {controller.close()}
        controller.sample(); await controller.sampling?.value
        let scroller = try previewScroller(in: controller)
        let panel = try XCTUnwrap(scroller.window)
        let document = try XCTUnwrap(scroller.documentView)
        XCTAssertTrue(screen.contains(panel.frame))
        XCTAssertGreaterThan(document.frame.height,scroller.contentSize.height)
        XCTAssertFalse(panel.ignoresMouseEvents, "预览必须能单独滚动查看")
        scroller.contentView.scroll(to:CGPoint(x:0,y:200))
        controller.sample(); await controller.sampling?.value
        XCTAssertEqual(scroller.contentView.bounds.minY,200,accuracy:0.01, "静止采样不能反复抢回用户预览位置")
        let tools = try XCTUnwrap(controller.window?.childWindows?.first { $0.contentView is ScreenshotEditorToolbar })
        XCTAssertFalse(panel.frame.intersects(tools.frame))
    }

    @MainActor
    private func capturePanelViews(in controller: ScreenshotScrollWindowController) -> [NSView] {
        (controller.window?.childWindows ?? []).compactMap(\.contentView).flatMap { [$0] + screenshotDescendants(of: $0) }
    }

    @MainActor
    private func previewScroller(in controller: ScreenshotScrollWindowController) throws -> NSScrollView {
        try XCTUnwrap(capturePanelViews(in: controller).compactMap { $0 as? NSScrollView }
            .first { $0.documentView is ScreenshotScrollPreviewImage })
    }

    @MainActor
    private func statusLabel(in controller: ScreenshotScrollWindowController) throws -> NSTextField {
        try XCTUnwrap(capturePanelViews(in: controller).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == L10n.text("scrollingScreenshotStatus") })
    }
}
