import AppKit
import XCTest
@testable import Seven

@MainActor final class ScreenshotToolPreferencesTests: XCTestCase {
    func testEveryToolRoundTripsOptionsIndependently() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ScreenshotToolPreferences(defaults: defaults)
        var expected: [Int: ScreenshotToolOptions] = [:]
        for tool in ScreenshotEditorTool.toolbarCases {
            var options = ScreenshotToolOptions(tool: tool)
            options.size = Double(tool.sizeRange.lowerBound + tool.rawValue)
            options.color = [0.2, 0.4, 0.6, 1]; options.opacity = 0.7
            options.filled = true; options.fillHasBorder = true; options.rounded = true; options.cornerRadius = 23
            options.dashed = true; options.blurred = true; options.curved = true; options.focusIsEllipse = true
            options.arrowStyle = ScreenshotArrowStyle.openHead.rawValue; options.pencilMode = ScreenshotPencilMode.highlighter.rawValue
            options.marker = ScreenshotAnnotationMarker.number.rawValue; options.textStyle = ScreenshotEditorTextStyle.plain.rawValue
            store.save(options, for: tool); expected[tool.rawValue] = options
        }
        let reopened = ScreenshotToolPreferences(defaults: defaults)
        for tool in ScreenshotEditorTool.toolbarCases { XCTAssertEqual(reopened.options(for: tool), expected[tool.rawValue]) }
    }

    func testFocusReadsExistingToolOptionsFromSlotEight() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var focus = ScreenshotToolOptions(tool: .highlight)
        focus.opacity = 0.32
        focus.focusIsEllipse = true
        var oldNumber = ScreenshotToolOptions(tool: .text)
        oldNumber.opacity = 0.75
        defaults.set(try JSONEncoder().encode(focus), forKey: "screenshotToolOptions.v1.8")
        defaults.set(try JSONEncoder().encode(oldNumber), forKey: "screenshotToolOptions.v1.7")

        let store = ScreenshotToolPreferences(defaults: defaults)
        XCTAssertEqual(store.options(for: .highlight), focus)
    }

    func testActualRectangleCircleAndArrowActionsRestoreAcrossNewWindow() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let image = NSImage(size: CGSize(width: 800, height: 500))
        func descendants(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(descendants) }
        func controls(_ controller: ScreenshotEditorWindowController) throws -> [NSView] { try screenshotEditorTestSubviews(controller) }
        func choose(_ tool: ScreenshotEditorTool, in views: [NSView]) throws {
            try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == tool.title }).performClick(nil)
        }
        let first = makeScreenshotEditorForTesting(image: image, preferences: ScreenshotToolPreferences(defaults: defaults))
        let views = try controls(first)
        let width = try XCTUnwrap(views.compactMap { $0 as? NSSlider }.first { $0.maxValue == 40 })
        let color = try XCTUnwrap(views.compactMap { $0 as? NSColorWell }.first)
        let mode = try XCTUnwrap(views.compactMap { $0 as? NSSegmentedControl }.first { $0.toolTip(forSegment: 0) == "描边" })
        for (tool, value) in [(ScreenshotEditorTool.rectangle, 12.0), (.ellipse, 7.0), (.arrow, 9.0)] {
            try choose(tool, in: views)
            width.doubleValue = value; NSApp.sendAction(try XCTUnwrap(width.action), to: width.target, from: width)
            color.color = NSColor(srgbRed: value / 20, green: 0.3, blue: 0.7, alpha: 1)
            if tool == .rectangle {
                let corner = try XCTUnwrap(views.compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == "圆角半径" })
                corner.doubleValue = 23; NSApp.sendAction(try XCTUnwrap(corner.action), to: corner.target, from: corner)
                mode.selectedSegment = 1; NSApp.sendAction(try XCTUnwrap(mode.action), to: mode.target, from: mode)
                let opacity = try XCTUnwrap(views.compactMap { $0 as? NSSlider }.first { $0.maxValue == 1 })
                opacity.doubleValue = 0.42; NSApp.sendAction(try XCTUnwrap(opacity.action), to: opacity.target, from: opacity)
                mode.selectedSegment = 2; NSApp.sendAction(try XCTUnwrap(mode.action), to: mode.target, from: mode)
                mode.selectedSegment = 1; NSApp.sendAction(try XCTUnwrap(mode.action), to: mode.target, from: mode)
                XCTAssertEqual(opacity.doubleValue, 0.42, accuracy: 0.001)
            }
            if tool == .arrow {
                let curved = try XCTUnwrap(views.compactMap { $0 as? NSSegmentedControl }.first { $0.accessibilityLabel() == "箭头线条类型" })
                curved.selectedSegment = 1; NSApp.sendAction(try XCTUnwrap(curved.action), to: curved.target, from: curved)
            }
        }
        first.close()
        let second = makeScreenshotEditorForTesting(image: image, preferences: ScreenshotToolPreferences(defaults: defaults))
        defer { second.close() }
        second.showWindow(nil)
        let restored = try controls(second)
        let canvas = try XCTUnwrap(restored.compactMap { $0 as? ScreenshotEditorCanvas }.first)
        XCTAssertNil(canvas.tool)
        for (tool, value) in [(ScreenshotEditorTool.rectangle, 12.0), (.ellipse, 7.0), (.arrow, 9.0)] {
            try choose(tool, in: restored)
            XCTAssertEqual(canvas.width, value)
            XCTAssertEqual(try XCTUnwrap(canvas.color.usingColorSpace(.sRGB)).redComponent, value / 20, accuracy: 0.001)
            if tool == .rectangle {
                XCTAssertEqual(canvas.opacity, 0.42, accuracy: 0.001)
                XCTAssertEqual(canvas.cornerRadius, 23)
                XCTAssertTrue(canvas.rounded)
                let opacity = try XCTUnwrap(restored.compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == "标注不透明度" })
                let corner = try XCTUnwrap(restored.compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == "圆角半径" })
                XCTAssertEqual(opacity.doubleValue, 0.42, accuracy: 0.001)
                XCTAssertEqual(corner.doubleValue, 23)
            }
            XCTAssertEqual(canvas.filled, tool == .rectangle)
            XCTAssertEqual(canvas.curved, tool == .arrow)
            for control in restored where control is SlidingSegmentedControl || control is NSSlider {
                for view in [control] + descendants(control) {
                    XCTAssertTrue(view.layer?.animationKeys()?.isEmpty ?? true, "恢复参数不能从默认状态播放动画")
                }
            }
        }
    }

    func testPureTextPlacementHasFillThenLosesDecorationAndDeselectsOnOutsideClick() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let canvas = ScreenshotEditorCanvas(image: NSImage(cgImage: try XCTUnwrap(rep.cgImage), size: CGSize(width: 400, height: 300)))
        canvas.tool = .text; canvas.width = 18; canvas.marker = .dot; canvas.textStyle = .plain
        func click(_ p: CGPoint) throws { canvas.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))) }
        try click(CGPoint(x: 20, y: 100))
        let preview = try XCTUnwrap(canvas.document.preview)
        XCTAssertTrue(preview.isPlacementPreview)
        XCTAssertGreaterThan(preview.textEditorFrame.width, preview.textEditorFrame.height)
        XCTAssertLessThan(preview.textEditorFrame.width / preview.textEditorFrame.height, 1.4)
        try click(CGPoint(x: 150, y: 100))
        let fixed = try XCTUnwrap(canvas.document.preview)
        XCTAssertFalse(fixed.isPlacementPreview); XCTAssertTrue(fixed.isEditingPreview)
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        editor.string = "你好"; canvas.textDidChange(Notification(name: NSText.didChangeNotification))
        try click(CGPoint(x: 350, y: 240))
        XCTAssertNil(canvas.selected)
        XCTAssertFalse(canvas.subviews.contains { $0 is ScreenshotTextEditorChrome })
        XCTAssertEqual(canvas.document.visible.count, 1)
    }

    func testAutomaticGrowthFitsRegionWhileManualMoveAndResizeRemainFree() throws {
        var text = ScreenshotEditorStroke(id: UUID(), tool: .text, start: CGPoint(x: 350, y: 5), end: .zero, color: .black, width: 18, opacity: 1)
        text.textLayoutBounds = CGRect(x: 0, y: 0, width: 400, height: 200); text.textMaximumWidth = 40
        text.layoutText("你好世界")
        XCTAssertTrue(try XCTUnwrap(text.textLayoutBounds).contains(text.textEditorFrame))
        text.translateText(to: CGPoint(x: 500, y: 400))
        XCTAssertGreaterThan(text.rect.maxX, 400)
        text.textWidthIsManual = true; text.textBoxWidth = 500; text.layoutText("你好世界")
        XCTAssertGreaterThan(text.textEditorFrame.width, 400)
    }
}
