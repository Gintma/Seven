import AppKit
import XCTest
@testable import Seven

@MainActor final class ScreenshotEditorTests:XCTestCase {
    private func stroke(_ tool:ScreenshotEditorTool = .rectangle,id:UUID = UUID(),end:CGPoint = CGPoint(x:50,y:50))->ScreenshotEditorStroke {
        ScreenshotEditorStroke(id:id,tool:tool,start:.zero,end:end,color:ThemePalette.system.accent,width:4,opacity:1)
    }
    func testTextMeasurementUsesEmptySpaceAndZeroFragmentPadding(){
        let font = NSFont.systemFont(ofSize: Design.ScreenshotEditor.textSize)
        let empty=ScreenshotEditorGeometry.textSize("",font:font)
        XCTAssertGreaterThan(empty.width,0);XCTAssertGreaterThan(empty.height,0)
        XCTAssertEqual(empty,ScreenshotEditorGeometry.textSize(" ",font:font))
    }
    func testHollowEllipseDoesNotSelectItsInterior(){
        let ellipse=stroke(.ellipse)
        XCTAssertFalse(ScreenshotEditorGeometry.hit(CGPoint(x:25,y:25),stroke:ellipse))
        XCTAssertTrue(ScreenshotEditorGeometry.hit(CGPoint(x:25,y:50),stroke:ellipse))
    }
    func testCurveHitSamplesActualBezierRatherThanEndpointChord() {
        var curve = stroke(.arrow, end: CGPoint(x: 100, y: 0))
        curve.curved = true; curve.control1 = CGPoint(x: 0, y: 100); curve.control2 = CGPoint(x: 100, y: 100)
        XCTAssertEqual(ScreenshotEditorGeometry.curvePoint(start: curve.start, control1: CGPoint(x: 0, y: 100), control2: CGPoint(x: 100, y: 100), end: curve.end, t: 0.5), CGPoint(x: 50, y: 75))
        XCTAssertTrue(ScreenshotEditorGeometry.hit(CGPoint(x: 50, y: 75), stroke: curve))
        XCTAssertFalse(ScreenshotEditorGeometry.hit(CGPoint(x: 50, y: 0), stroke: curve))
    }
    func testSegmentHitUsesRecoveredPointerBoxEdges() {
        XCTAssertTrue(ScreenshotEditorGeometry.segmentCrossesPointerBox(.zero, CGPoint(x: 20, y: 0), center: CGPoint(x: 10, y: 0), radius: 3))
        XCTAssertFalse(ScreenshotEditorGeometry.segmentCrossesPointerBox(.zero, CGPoint(x: 20, y: 0), center: CGPoint(x: 10, y: 4), radius: 3))
        XCTAssertFalse(ScreenshotEditorGeometry.segmentCrossesPointerBox(CGPoint(x: 9, y: 0), CGPoint(x: 11, y: 0), center: CGPoint(x: 10, y: 0), radius: 3), "原四边相交算法不把完全在方框内的短线段当作边交点")
        XCTAssertTrue(ScreenshotEditorGeometry.triangleContains(CGPoint(x: 5, y: 0), [.zero, CGPoint(x: 10, y: 0), CGPoint(x: 5, y: 10)]))
        XCTAssertFalse(ScreenshotEditorGeometry.triangleContains(CGPoint(x: 20, y: 0), [.zero, CGPoint(x: 10, y: 0), CGPoint(x: 5, y: 10)]))
    }

    func testSelectionResizeRebasesAllHistoryVersionsWithoutMovingGlobalAnnotations() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let cg = try XCTUnwrap(rep.cgImage)
        let context = FrozenSelectionContext(screenFrame: CGRect(x: -200, y: 40, width: 400, height: 300), localSelection: CGRect(x: 50, y: 40, width: 100, height: 80), image: cg)
        let canvas = ScreenshotEditorCanvas(image: try XCTUnwrap(context.croppedImage(in: context.localSelection)))
        let first = stroke(end: CGPoint(x: 80, y: 50)); canvas.document.commit(first)
        var moved = first; moved.translate(CGPoint(x: 10, y: 5)); canvas.document.commit(moved)
        let overlay = ScreenshotEditorSelectionOverlay(context: context, canvas: canvas)
        overlay.replaceSelection(CGRect(x: 30, y: 20, width: 180, height: 150))
        XCTAssertEqual(overlay.globalSelection, CGRect(x: -170, y: 60, width: 180, height: 150))
        XCTAssertEqual(canvas.image.size, NSSize(width: 180, height: 150))
        XCTAssertEqual(canvas.document.visible.first?.start, CGPoint(x: 30, y: 25))
        canvas.document.undo()
        XCTAssertEqual(canvas.document.visible.first?.start, CGPoint(x: 20, y: 20), "撤销只恢复笔画自身移动，不受选区原点改变影响")
        XCTAssertEqual(canvas.document.visible.first.map { $0.start.x + overlay.selection.minX }, 50)
    }

    func testRetinaExportKeepsPixelContentAtOriginalPositions() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: 20, height: 10)
        for y in 0..<20 { for x in 0..<40 { rep.setColor(y < 10 ? NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1) : NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), atX: x, y: y) } }
        XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: 10, y: 2)).redComponent, 1, accuracy: 0.01, "输入fixture必须先包含有效像素")
        let base = NSImage(size: rep.size); base.addRepresentation(rep)
        let output = ScreenshotEditorRenderer.image(base: base, strokes: [])
        let bitmap = try XCTUnwrap(output.representations.first as? NSBitmapImageRep)
        for y in [2, 8, 12, 18] {
            let actual = try XCTUnwrap(bitmap.colorAt(x: 10, y: y)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(actual.redComponent, y < 10 ? 1 : 0, accuracy: 0.01)
            XCTAssertEqual(actual.blueComponent, y < 10 ? 0 : 1, accuracy: 0.01)
        }
    }

    func testRetinaExportPlacesFilledAnnotationAtLogicalCoordinates() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: 20, height: 10)
        for y in 0..<20 { for x in 0..<40 { rep.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y) } }
        let base = NSImage(size: rep.size); base.addRepresentation(rep)
        var annotation = stroke(end: CGPoint(x: 10, y: 5))
        annotation.start = CGPoint(x: 4, y: 2); annotation.filled = true
        annotation.color = NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1)
        let output = ScreenshotEditorRenderer.image(base: base, strokes: [annotation])
        let bitmap = try XCTUnwrap(output.representations.first as? NSBitmapImageRep)
        let inside = try XCTUnwrap(bitmap.colorAt(x: 12, y: 13))
        let outside = try XCTUnwrap(bitmap.colorAt(x: 2, y: 13))
        XCTAssertEqual(inside.greenComponent, 1, accuracy: 0.01)
        XCTAssertEqual(outside.redComponent, 1, accuracy: 0.01)
    }

    func testCommittedTextCanBeEditedAgainAndUndoRestoresItsPreviousContent() throws {
        let image = NSImage(size: NSSize(width: 300, height: 200))
        let canvas = ScreenshotEditorCanvas(image: image)
        var original = stroke(.text, end: CGPoint(x: 150, y: 70))
        original.start = CGPoint(x: 30, y: 30); original.width = 20; original.text = "原文"
        canvas.document.commit(original)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 50, y: 40), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
        canvas.mouseDown(with: event)
        let nativeEditor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual(nativeEditor.string, "原文")
        nativeEditor.string = "修改后"
        canvas.textDidChange(Notification(name: NSText.didChangeNotification))
        canvas.commitText()
        XCTAssertEqual(canvas.document.visible.count, 1)
        XCTAssertEqual(canvas.document.visible.first?.text, "修改后")
        XCTAssertEqual(canvas.document.visible.first?.id, original.id)
        canvas.document.undo()
        XCTAssertEqual(canvas.document.visible.first?.text, "原文")
    }

    func testShapeModesRetainOpaqueBorderAndEditAfterSwitchingTools() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let base = NSImage(cgImage: try XCTUnwrap(rep.cgImage), size: CGSize(width: 120, height: 100))
        var shape = stroke(.rectangle, end: CGPoint(x: 90, y: 80))
        shape.start = CGPoint(x: 20, y: 20); shape.width = 6
        shape.color = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1); shape.opacity = 0.25
        for mode in ScreenshotShapeMode.allCases {
            shape.shapeMode = mode
            let output = ScreenshotEditorRenderer.image(base: base, strokes: [shape])
            let raster = NSBitmapImageRep(cgImage: try XCTUnwrap(output.cgImage(forProposedRect: nil, context: nil, hints: nil)))
            let center = try XCTUnwrap(raster.colorAt(x: raster.pixelsWide / 2, y: raster.pixelsHigh / 2))
            XCTAssertEqual(center.alphaComponent, mode == .outline ? 0 : mode == .fill ? 0.25 : 1, accuracy: 0.02)
            if mode == .fill {
                let border = try XCTUnwrap(raster.colorAt(x: raster.pixelsWide * 20 / 120, y: raster.pixelsHigh / 2))
                XCTAssertEqual(border.alphaComponent, 1, accuracy: 0.02)
            }
        }
        shape.shapeMode = .fill
        let canvas = ScreenshotEditorCanvas(image: base)
        canvas.document.commit(shape); canvas.tool = .pencil; canvas.selected = nil
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: click)
        XCTAssertEqual(canvas.selected, shape.id); XCTAssertEqual(canvas.tool, .rectangle)
        XCTAssertTrue(canvas.fillHasBorder); XCTAssertEqual(canvas.opacity, 0.25)
        canvas.updateSelected { $0.cornerRadius = 20; $0.rounded = true; $0.shapeMode = .solid }
        XCTAssertEqual(canvas.document.visible.first?.shapeMode, .solid)
        canvas.document.undo(); XCTAssertEqual(canvas.document.visible.first?.shapeMode, .fill)
    }

    func testFocusShapesEachParticipateInCreationOrder() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
        for y in 0..<200 { for x in 0..<300 { rep.setColor(white, atX: x, y: y) } }
        let base = NSImage(cgImage: try XCTUnwrap(rep.cgImage), size: CGSize(width: 300, height: 200))
        var rectangle = stroke(.highlight, end: CGPoint(x: 130, y: 130))
        rectangle.start = CGPoint(x: 30, y: 30); rectangle.cornerRadius = 20; rectangle.opacity = 0.4
        var ellipse = stroke(.highlight, end: CGPoint(x: 240, y: 140))
        ellipse.start = CGPoint(x: 100, y: 30); ellipse.focusIsEllipse = true; ellipse.opacity = 0.4
        func pixels(_ marks: [ScreenshotEditorStroke]) throws -> NSBitmapImageRep {
            let image = ScreenshotEditorRenderer.image(base: base, strokes: marks)
            return NSBitmapImageRep(cgImage: try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        }
        let single = try pixels([rectangle]), multiple = try pixels([rectangle, ellipse])
        func red(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> CGFloat {
            try XCTUnwrap(bitmap.colorAt(x: x, y: 200-y)?.usingColorSpace(.deviceRGB)).redComponent
        }
        XCTAssertLessThan(try red(multiple, 280, 180), try red(single, 280, 180))
        XCTAssertLessThan(try red(multiple, 80, 80), 0.95)
        XCTAssertLessThan(try red(multiple, 170, 85), 0.95)
        XCTAssertEqual(try red(multiple, 110, 85), 1, accuracy: 0.01)
        XCTAssertLessThan(try red(multiple, 31, 31), 0.95, "圆角外仍应压暗")
        XCTAssertLessThan(try red(multiple, 239, 139), 0.95, "椭圆外仍应压暗")
    }

    func testBorderStyleExportsFrameWithSolidTextAndNoFill() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let base = NSImage(cgImage: try XCTUnwrap(rep.cgImage), size: CGSize(width: 400, height: 300))
        var mark = stroke(.text); mark.start = CGPoint(x: 100, y: 100); mark.width = 24
        mark.color = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
        mark.textStyle = .outline; mark.textWidthIsManual = true; mark.textBoxWidth = 180; mark.layoutText("HI")
        let attrs = ScreenshotEditorTextRendering.attributes(for: mark)
        XCTAssertNil(attrs[.strokeWidth]); XCTAssertNil(attrs[.strokeColor])
        let paragraph = try XCTUnwrap(attrs[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(paragraph.alignment, .left)
        let image = ScreenshotEditorRenderer.image(base: base, strokes: [mark])
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        let frame = mark.textDecorationFrame.insetBy(dx: Design.AnnotationEditor.textBorderInset, dy: Design.AnnotationEditor.textBorderInset)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: Int(frame.maxX), y: Int(300-frame.midY))).alphaComponent, 0.1)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: Int(mark.rect.maxX-10), y: Int(300-mark.rect.midY))).alphaComponent, 0, accuracy: 0.01)
    }

    func testFontChangesDoNotResizeAnnotationMarkerOrCropLargeGlyphs() throws {
        var mark = stroke(.text); mark.width = 18
        mark.marker = .number; mark.markerAnchor = CGPoint(x: 20, y: 100)
        mark.start = CGPoint(x: 80, y: 100); mark.layoutText("你好")
        let markerSize = mark.markerSize
        mark.width = 100; mark.layoutText("你好")
        XCTAssertEqual(mark.markerSize, markerSize)
        let measured = ScreenshotEditorGeometry.textSize("你好", font: Design.ScreenshotEditor.font(size: 100))
        XCTAssertGreaterThanOrEqual(mark.rect.width, measured.width)
        XCTAssertGreaterThanOrEqual(mark.rect.height, measured.height)
        mark.textWidthIsManual = true; mark.textBoxWidth = 24; mark.layoutText("你好")
        let character = ScreenshotEditorGeometry.textSize("你", font: Design.ScreenshotEditor.font(size: 100))
        XCTAssertGreaterThanOrEqual(mark.rect.width, character.width, "手动窄框也不能裁掉单个字形")
    }
}

extension ScreenshotEditorTests {
    private func outputFixture() throws -> NSImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 100, height: 50))
    }

    func testExportCutsAllLayersIntoTransparentRetinaCornersWithoutChangingSize() throws {
        let canvas = ScreenshotEditorCanvas(image: try outputFixture())
        let square = ScreenshotEditorStroke(id: UUID(), tool: .rectangle, start: .zero, end: CGPoint(x: 100, y: 50), color: .blue, width: 3, opacity: 1, filled: true)
        canvas.document.commit(square)
        canvas.outputCornerRadius = 20
        let result = canvas.renderedImage()
        XCTAssertEqual(result.size, CGSize(width: 100, height: 50))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(result.tiffRepresentation)))
        XCTAssertEqual(bitmap.pixelsWide, 200); XCTAssertEqual(bitmap.pixelsHigh, 100)
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 199, y: 0), CGPoint(x: 0, y: 99), CGPoint(x: 199, y: 99)] {
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: Int(point.x), y: Int(point.y))).alphaComponent, 0, accuracy: 0.01)
        }
        let middle = try XCTUnwrap(bitmap.colorAt(x: 100, y: 50)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(middle.alphaComponent, 0.99); XCTAssertGreaterThan(middle.blueComponent, 0.99)
        canvas.outputCornerRadius = 0
        let normal = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(canvas.renderedImage().tiffRepresentation)))
        XCTAssertGreaterThan(try XCTUnwrap(normal.colorAt(x: 0, y: 0)).alphaComponent, 0.99)
    }

    func testFocusCutoutNeverRestoresTheUnredactedBaseImage() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 120, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let light = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
        let dark = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
        for y in 0..<120 {
            for x in 0..<200 {
                let color = (x / 2 + y / 2).isMultiple(of: 2) ? light : dark
                bitmap.setColor(color, atX: x, y: y)
            }
        }
        let base = NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: CGSize(width: 200, height: 120))
        let focus = ScreenshotEditorStroke(id: UUID(), tool: .highlight, start: CGPoint(x: 100, y: 20), end: CGPoint(x: 190, y: 100), color: .black, width: 3, opacity: 0.6)
        func color(_ image: NSImage, at point: CGPoint) throws -> NSColor {
            let bitmap = try XCTUnwrap(ScreenshotSaving.bitmap(image))
            return try XCTUnwrap(bitmap.colorAt(x: Int(point.x), y: bitmap.pixelsHigh - 1 - Int(point.y))?
                .usingColorSpace(.deviceRGB))
        }
        for blurred in [false, true] {
            var cover = ScreenshotEditorStroke(id: UUID(), tool: .mosaic, start: .zero, end: CGPoint(x: 200, y: 120), color: .red, width: 10, opacity: 1)
            cover.blurred = blurred
            let filtered = ScreenshotEditorRenderer.image(base: base, strokes: [cover])
            let masked = [[focus, cover], [cover, focus]].map { ScreenshotEditorRenderer.image(base: base, strokes: $0) }
            var foundDifferentPixel = false
            for x in 120..<130 {
                let point = CGPoint(x: x, y: 60)
                let raw = try color(base, at: point), redacted = try color(filtered, at: point)
                if abs(raw.redComponent - redacted.redComponent) + abs(raw.blueComponent - redacted.blueComponent) > 0.1 {
                    foundDifferentPixel = true
                    for image in masked {
                        let visible = try color(image, at: point)
                        XCTAssertEqual(visible.redComponent, redacted.redComponent, accuracy: 0.01)
                        XCTAssertEqual(visible.greenComponent, redacted.greenComponent, accuracy: 0.01)
                        XCTAssertEqual(visible.blueComponent, redacted.blueComponent, accuracy: 0.01)
                    }
                    break
                }
            }
            XCTAssertTrue(foundDifferentPixel, "样例必须确实经过打码，才能验证聚焦没有恢复原图")
        }
    }

    private func sizingContext(scaleX: Int = 2, scaleY: Int = 2) throws -> FrozenSelectionContext {
        let pixels = try XCTUnwrap(CGContext(data: nil, width: 400 * scaleX, height: 300 * scaleY, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        return FrozenSelectionContext(screenFrame: CGRect(x: -200, y: 100, width: 400, height: 300), localSelection: CGRect(x: 20, y: 50, width: 150, height: 100), image: pixels)
    }

    func testRetinaNumericSizesUseOutputPixelsAndKeepTopLeftWhenTheyFit() throws {
        let context = try sizingContext()
        let rect = ScreenshotSelectionSizing.resized(context.localSelection, width: 399, height: 201, ratio: .free, context: context)
        XCTAssertEqual(ScreenshotSelectionSizing.pixelSize(rect, context: context), CGSize(width: 399, height: 201))
        XCTAssertEqual(rect.minX, context.localSelection.minX)
        XCTAssertEqual(rect.maxY, context.localSelection.maxY)
        let image = try XCTUnwrap(context.croppedImage(in: rect)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(image.width, 399); XCTAssertEqual(image.height, 201)
    }

    func testAllRequestedRatiosAndNumericHeightResizeFitTheScreen() throws {
        let context = try sizingContext()
        for ratio in ScreenshotAspectRatio.allCases where ratio != .free {
            let rect = ScreenshotSelectionSizing.resized(context.localSelection, width: 320, ratio: ratio, context: context)
            let size = ScreenshotSelectionSizing.pixelSize(rect, context: context)
            XCTAssertEqual(size.width / size.height, try XCTUnwrap(ratio.value), accuracy: 0.01)
            XCTAssertTrue(CGRect(origin: .zero, size: context.screenFrame.size).contains(rect))
        }
        let rect = ScreenshotSelectionSizing.resized(context.localSelection, height: 300, ratio: .desktop, context: context)
        XCTAssertEqual(ScreenshotSelectionSizing.pixelSize(rect, context: context), CGSize(width: 480, height: 300))
        let full = ScreenshotSelectionSizing.resized(context.localSelection, width: 100000, height: 500000, ratio: .free, context: context)
        XCTAssertEqual(full, CGRect(origin: .zero, size: context.screenFrame.size))
        let wide = ScreenshotSelectionSizing.resized(context.localSelection, width: 100000, ratio: .wide, context: context)
        XCTAssertEqual(ScreenshotSelectionSizing.pixelSize(wide, context: context), CGSize(width: 800, height: 450))
    }

    func testEveryResizeHandleKeepsRatioAndFreeUsesExistingGeometry() throws {
        let context = try sizingContext()
        let original = CGRect(x: 100, y: 100, width: 120, height: 80)
        for handle in FrozenSelectionHandle.allCases {
            let point = CGPoint(x: 390, y: 290)
            let rect = ScreenshotSelectionSizing.dragged(original, handle: handle, to: point, ratio: .tall, context: context)
            XCTAssertGreaterThan(rect.width, 0); XCTAssertGreaterThan(rect.height, 0)
            XCTAssertEqual(rect.width / rect.height, 9.0 / 16, accuracy: 0.0001)
            XCTAssertTrue(CGRect(origin: .zero, size: context.screenFrame.size).contains(rect))
            XCTAssertEqual(ScreenshotSelectionSizing.dragged(original, handle: handle, to: point, ratio: .free, context: context),
                           FrozenSelectionGeometry.resized(original, handle: handle, to: point, within: context.screenFrame.size))
        }
        let nonuniform = try sizingContext(scaleX: 2, scaleY: 3)
        let rect = ScreenshotSelectionSizing.dragged(original, handle: .topRight, to: CGPoint(x: 350, y: 250), ratio: .wide, context: nonuniform)
        let pixels = ScreenshotSelectionSizing.pixelSize(rect, context: nonuniform)
        XCTAssertEqual(pixels.width / pixels.height, 16.0 / 9, accuracy: 0.01)
    }

    func testExportIgnoresOldLineOpacityAndHighlighterKeepsTextVisible() throws {
        let base = NSImage(size: CGSize(width: 240, height: 120), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            NSColor.black.setFill(); CGRect(x: 80, y: 55, width: 10, height: 10).fill(); return true
        }
        for tool in [ScreenshotEditorTool.line, .arrow] {
            for style in ScreenshotArrowStyle.allCases {
                var mark = ScreenshotEditorStroke(id: UUID(), tool: tool, start: CGPoint(x: 20, y: 60), end: CGPoint(x: 210, y: 60), color: .red, width: 4, opacity: 0.1)
                mark.arrowStyle = style
                let faded = try XCTUnwrap(ScreenshotEditorRenderer.image(base: base, strokes: [mark]).tiffRepresentation)
                mark.opacity = 1
                XCTAssertEqual(ScreenshotEditorRenderer.image(base: base, strokes: [mark]).tiffRepresentation, faded)
            }
        }
        var mark = ScreenshotEditorStroke(id: UUID(), tool: .pencil, start: CGPoint(x: 20, y: 60), end: CGPoint(x: 210, y: 60), color: .red, width: 20, opacity: 1)
        mark.pencilMode = .highlighter; mark.opacity = Design.ScreenshotEditor.highlighterOpacity
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(ScreenshotEditorRenderer.image(base: base, strokes: [mark]).tiffRepresentation)))
        let sample = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(sample.redComponent, 1, accuracy: 0.02)
        // Color management alters blended channel values; verify translucency and text contrast without tying to a display color profile.
        XCTAssertGreaterThan(sample.greenComponent, 0.2)
        XCTAssertLessThan(sample.greenComponent, 0.95)
        let text = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide * 85 / 240, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(text.greenComponent, sample.greenComponent - 0.2)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1, time: TimeInterval = 10) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1))
    }

    func testOnlyTwoCompletedBlankClicksWithinTheIntervalExport() throws {
        let blank = CGPoint(x: 150, y: 100)
        let object = CGPoint(x: 50, y: 50)
        let interval = NSEvent.doubleClickInterval
        for scenario in ["inherited", "drag", "object", "stale", "blank"] {
            let canvas = ScreenshotEditorCanvas(image: NSImage(size: CGSize(width: 200, height: 120)))
            var exports = 0
            var drags = 0
            canvas.onEmptyDoubleClick = { exports += 1; return true }
            canvas.onRegionDragBegan = { _ in }
            canvas.onRegionDragged = { _ in drags += 1 }
            func click(_ point: CGPoint, count: Int = 1, time: TimeInterval = 10) throws {
                canvas.mouseDown(with: try mouse(.leftMouseDown, at: point, clicks: count, time: time))
                canvas.mouseUp(with: try mouse(.leftMouseUp, at: point, clicks: count, time: time + 0.001))
            }
            if scenario == "object" {
                var mark = stroke(end: CGPoint(x: 80, y: 80))
                mark.start = CGPoint(x: 20, y: 20)
                canvas.document.commit(mark)
                try click(object)
            } else if scenario == "drag" {
                canvas.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 70)))
                canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: blank))
                canvas.mouseUp(with: try mouse(.leftMouseUp, at: blank))
                XCTAssertEqual(drags, 1)
            } else if scenario != "inherited" {
                try click(blank)
            }
            XCTAssertEqual(exports, 0, scenario)
            try click(blank, count: 2, time: 10 + (scenario == "stale" ? interval + 1 : interval / 4))
            XCTAssertEqual(exports, scenario == "blank" ? 1 : 0, scenario)
        }
    }

    func testAnnotationCompositionCommitsOnlyConfirmedText() throws {
        let canvas = ScreenshotEditorCanvas(image: NSImage(size: CGSize(width: 400, height: 300)))
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.close() }
        canvas.tool = .text
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 80, y: 130)))
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        let automaticRange = NSRange(location: NSNotFound, length: 0)
        editor.insertText("如果", replacementRange: automaticRange)
        let composition = "quandui"
        editor.setMarkedText(composition, selectedRange: NSRange(location: composition.utf16.count, length: 0),
                             replacementRange: automaticRange)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.markedRange().length, composition.utf16.count)
        XCTAssertTrue(canvas.document.history.isEmpty)
        editor.insertText("全对", replacementRange: automaticRange)
        XCTAssertFalse(editor.hasMarkedText())
        canvas.commitText()
        XCTAssertEqual(canvas.document.history.count, 1)
        XCTAssertEqual(canvas.document.visible.map(\.text), ["如果全对"])
    }

    func testHighlighterLocksRecognizedHeightAndHonorsManualOverride() async throws {
        let image = NSImage(size: CGSize(width: 400, height: 300), flipped: false) { _ in true }
        let line = CGRect(x: 0.1, y: 0.4, width: 0.6, height: 0.1)
        let canvas = ScreenshotEditorCanvas(image: image, lineRecognizer: EditorLineRecognizer(line: line))
        defer { canvas.cancelHighlighterRecognition() }
        canvas.tool = .pencil
        canvas.pencilMode = .highlighter
        canvas.width = 8
        let start = CGPoint(x: 100, y: 130)
        let end = CGPoint(x: 250, y: 240)
        let down = try mouse(.leftMouseDown, at: start)
        let height = line.height * image.size.height + 2 * Design.ScreenshotEditor.highlighterTextPadding
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        repeat {
            canvas.mouseDown(with: down)
            if canvas.document.preview?.width == height { break }
            try await Task.sleep(for: .milliseconds(5))
        } while ContinuousClock.now < deadline
        XCTAssertEqual(canvas.document.preview?.width, height)
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: end))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: end))
        let automatic = try XCTUnwrap(canvas.document.visible.last)
        XCTAssertEqual(automatic.width, height)
        XCTAssertEqual(automatic.start.y, automatic.end.y)
        canvas.highlighterManualHeight = true
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 50, y: 130)))
        XCTAssertEqual(canvas.document.preview?.width, 8)
    }

    func testAuxiliaryEditorIsReleasedAfterItsCloseCallback() async throws {
        let closed = expectation(description: "editor close cleanup")
        weak var retained: ScreenshotEditorWindowController?
        var window: NSWindow?
        autoreleasepool {
            let editor = makeScreenshotEditorForTesting(image: NSImage(size: CGSize(width: 200, height: 120)),
                                                        preferences: ScreenshotToolPreferences(defaults: nil))
            retained = editor
            window = editor.window
            ScreenshotAuxiliaryWindows.show(editor, activateApplication: false) { closed.fulfill() }
        }
        XCTAssertNotNil(retained)
        try XCTUnwrap(window).close()
        await fulfillment(of: [closed], timeout: 1)
        XCTAssertNil(retained)
    }
}

private struct EditorLineRecognizer: ScreenshotTextLineRecognizing {
    let line: CGRect
    func lines(in image: CGImage) async throws -> [CGRect] { [line] }
}
