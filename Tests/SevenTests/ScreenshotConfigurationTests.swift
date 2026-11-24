import AppKit
import XCTest
@testable import Seven

@MainActor final class ScreenshotConfigurationTests:XCTestCase {
    private func image()->NSImage {
        let image=NSImage(size:CGSize(width:200,height:120));image.lockFocus();NSColor.white.setFill();CGRect(x:0,y:0,width:200,height:120).fill();image.unlockFocus();return image
    }
    private func key(_ character:String,keyCode:UInt16=0,flags:NSEvent.ModifierFlags=[] )throws->NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:character,charactersIgnoringModifiers:character,isARepeat:false,keyCode:keyCode))
    }
    func testLocalKeysVisibilityAndConflictRoundTrip() throws {
        let name="SevenToolbar.\(UUID().uuidString)",defaults=try XCTUnwrap(UserDefaults(suiteName:name));defer{defaults.removePersistentDomain(forName:name)}
        let preferences=ScreenshotToolbarPreferences(defaults:defaults)
        let rectangleDefault = try XCTUnwrap(ScreenshotToolbarAction.rectangle.defaultKey)
        let ellipseDefault = try XCTUnwrap(ScreenshotToolbarAction.ellipse.defaultKey)
        let defaultKeys = Set(ScreenshotToolbarAction.allCases.compactMap(\.defaultKey))
        let alternateKey = try XCTUnwrap(ScreenshotToolbarAction.allowedKeys.first { !defaultKeys.contains($0) })
        XCTAssertEqual(preferences.hint(.rectangle), rectangleDefault.uppercased())
        XCTAssertFalse(preferences.setKey(ellipseDefault, for: .rectangle))
        XCTAssertTrue(preferences.setKey(alternateKey, for: .ellipse))
        XCTAssertTrue(preferences.setKey(ellipseDefault, for: .rectangle))
        preferences.setVisible(false,for:.rectangle)
        XCTAssertEqual(preferences.action(for: try key(ellipseDefault)), .rectangle)
        XCTAssertNil(preferences.action(for: try key(ellipseDefault, flags: .option)))
        XCTAssertFalse(preferences.setKey("xx",for:.save));XCTAssertFalse(preferences.setKey("中",for:.save))
        let restored=ScreenshotToolbarPreferences(defaults:defaults)
        XCTAssertFalse(restored.item(.rectangle).visible)
        XCTAssertEqual(restored.item(.rectangle).key, ellipseDefault)
        XCTAssertEqual(restored.item(.ellipse).key, alternateKey)
    }
    func testHiddenToolStillWorksFromItsLocalKey() throws {
        let preferences=ScreenshotToolbarPreferences();preferences.setVisible(false,for:.rectangle)
        let editor=makeScreenshotEditorForTesting(image:image(),preferences:ScreenshotToolPreferences(),toolbarPreferences:preferences)
        defer{editor.close()}
        let editorViews = try screenshotEditorTestSubviews(editor)
        let canvas=try XCTUnwrap(editorViews.compactMap{$0 as? ScreenshotEditorCanvas}.first)
        let button = try XCTUnwrap(editorViews.compactMap { $0 as? NSButton }
            .first { $0.title == ScreenshotEditorTool.rectangle.title })
        XCTAssertTrue(button.isHidden)
        let rectangleDefault = try XCTUnwrap(ScreenshotToolbarAction.rectangle.defaultKey)
        XCTAssertTrue(editor.performShortcut(try key(rectangleDefault)))
        XCTAssertEqual(canvas.tool, .rectangle)
        preferences.setVisible(false,for:.save);XCTAssertEqual(canvas.tool,.rectangle)
        let saveButton = try XCTUnwrap(editorViews.compactMap { $0 as? NSButton }
            .first { $0.title == ScreenshotToolbarAction.save.title })
        XCTAssertTrue(saveButton.isHidden)
    }
    private func editorCanvas(_ editor: ScreenshotEditorWindowController) throws -> ScreenshotEditorCanvas {
        let root = try XCTUnwrap(editor.window?.contentView)
        return try XCTUnwrap(screenshotDescendants(of: root).compactMap { $0 as? ScreenshotEditorCanvas }.first)
    }

    func testPinEditingUpdatesSamePinWithoutCopyAndPreservesEditableLayers() throws {
        let toolbar=ScreenshotToolbarPreferences()
        let pin=ScreenshotPinWindowController(image:image(),preferences:ScreenshotPinPreferences(),toolbarPreferences:toolbar)
        defer{pin.close()}
        ScreenshotAuxiliaryWindows.show(pin,activateApplication:false)
        pin.window?.setContentSize(CGSize(width:100,height:60))
        let originalFrame=try XCTUnwrap(pin.window).frame
        let originalContent=pin.contentFrame
        var copies=0
        XCTAssertNil(try XCTUnwrap(pin.editingContext).background)
        let editor=try XCTUnwrap(pin.makeEditor(preferences:ScreenshotToolPreferences(),clipboardWriter:{_ in copies+=1;return true}))
        let canvas = try editorCanvas(editor)
        XCTAssertEqual(canvas.convert(canvas.bounds,to:nil).width,originalContent.width,accuracy:0.001)
        XCTAssertEqual(canvas.convert(canvas.bounds,to:nil).height,originalContent.height,accuracy:0.001)
        XCTAssertEqual(canvas.bounds.width,pin.originalImage.size.width,accuracy:0.001)
        XCTAssertEqual(canvas.bounds.height,pin.originalImage.size.height,accuracy:0.001)
        XCTAssertEqual(pin.window?.frame,originalFrame);XCTAssertTrue(pin.window?.isVisible ?? false)
        var stroke=ScreenshotEditorStroke(id:UUID(),tool:.rectangle,start:CGPoint(x:40,y:20),end:CGPoint(x:160,y:100),color:.red,width:2,opacity:0.5)
        stroke.shapeMode = .fill;canvas.document.commit(stroke)
        XCTAssertTrue(editor.performShortcut(try key("\r",keyCode:36)))
        XCTAssertEqual(copies,0);XCTAssertEqual(pin.annotationDocument.visible.count,1);XCTAssertEqual(pin.window?.frame,originalFrame)
        let firstBitmap=try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(pin.pngData())))
        let firstColor=try XCTUnwrap(firstBitmap.colorAt(x:firstBitmap.pixelsWide/2,y:firstBitmap.pixelsHigh/2)).usingColorSpace(.deviceRGB)
        XCTAssertLessThan(firstColor?.greenComponent ?? 1,0.95)
        XCTAssertGreaterThan(firstColor?.greenComponent ?? 0,0.2)
        let next=try XCTUnwrap(pin.makeEditor(preferences:ScreenshotToolPreferences(),clipboardWriter:{_ in copies+=1;return true}))
        let nextCanvas = try editorCanvas(next)
        XCTAssertEqual(nextCanvas.document.visible.first?.id,stroke.id)
        XCTAssertTrue(next.performShortcut(try key("\r",keyCode:36)))
        let bitmap=try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(pin.pngData())))
        let color=try XCTUnwrap(bitmap.colorAt(x:bitmap.pixelsWide/2,y:bitmap.pixelsHigh/2)).usingColorSpace(.deviceRGB)
        XCTAssertEqual(color?.greenComponent ?? 0,firstColor?.greenComponent ?? 1,accuracy:0.01,"再次编辑不能把上一次半透明标注重复叠加")
        let cancel=try XCTUnwrap(pin.makeEditor(preferences:ScreenshotToolPreferences()))
        let cancelCanvas = try editorCanvas(cancel)
        cancelCanvas.document.undo();cancel.close();XCTAssertEqual(pin.annotationDocument.visible.count,1)
        XCTAssertFalse(cancel.performShortcut(try key("\r",keyCode:36)));XCTAssertEqual(pin.annotationDocument.visible.count,1)
    }
    func testPinArrowMovementIsOnePhysicalPixel() throws {
        let pin=ScreenshotPinWindowController(image:image(),preferences:ScreenshotPinPreferences());defer{pin.close()}
        let window=try XCTUnwrap(pin.window),before=pin.contentFrame
        let scale=window.screen?.backingScaleFactor ?? 1
        XCTAssertTrue(pin.handleKey(try key("",keyCode:124)))
        XCTAssertEqual(pin.contentFrame.minX-before.minX,1/scale,accuracy:0.001)
        XCTAssertTrue(pin.handleKey(try key("",keyCode:123)))
        XCTAssertEqual(pin.contentFrame.minX,before.minX,accuracy:0.001)
        let aligned=ScreenshotPinGeometry.aligned(CGRect(x:1.25,y:2.25,width:123.5,height:77.5),scale:2)
        XCTAssertEqual(aligned.minX*2,(aligned.minX*2).rounded())
    }
    func testNamesFormatsAndUniqueSavePreserveOriginalPixels() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:folder)}
        let png=try XCTUnwrap(ScreenshotSaving.data(image(),format:.png)),jpeg=try XCTUnwrap(ScreenshotSaving.data(image(),format:.jpeg))
        let a=try ScreenshotSaving.writeUnique(png,directory:folder,name:"Seven_test.png")
        let b=try ScreenshotSaving.writeUnique(jpeg,directory:folder,name:"Seven_test.png")
        XCTAssertNotEqual(a,b);XCTAssertEqual(try Data(contentsOf:a),png);XCTAssertEqual(try Data(contentsOf:b),jpeg)
        XCTAssertNotNil(NSBitmapImageRep(data:jpeg))
    }
    func testDoubleClickBlankDoesNotOverrideExistingObjectEditing() throws {
        let canvas=ScreenshotEditorCanvas(image:image());canvas.tool=nil
        var completed=0;canvas.onEmptyDoubleClick={completed+=1;return true}
        func event(_ point:CGPoint,type:NSEvent.EventType = .leftMouseDown,clicks:Int = 2)throws->NSEvent{try XCTUnwrap(NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:clicks,pressure:1))}
        canvas.mouseDown(with:try event(CGPoint(x:150,y:100),clicks:1))
        canvas.mouseUp(with:try event(CGPoint(x:150,y:100),type:.leftMouseUp,clicks:1))
        canvas.mouseDown(with:try event(CGPoint(x:150,y:100)));XCTAssertEqual(completed,1)
        let stroke=ScreenshotEditorStroke(id:UUID(),tool:.rectangle,start:CGPoint(x:20,y:20),end:CGPoint(x:80,y:80),color:.red,width:2,opacity:1)
        canvas.document.commit(stroke);canvas.mouseDown(with:try event(CGPoint(x:50,y:50)));XCTAssertEqual(completed,1)
    }
    func testHierarchyContainsParentsAndWindowWithoutSiblings() {
        let window=FrozenWindowCandidate(id:1,frame:CGRect(x:0,y:0,width:800,height:600))
        let button=FrozenSmartRegion(role:"AXButton",frame:CGRect(x:30,y:40,width:80,height:30))
        let panel=FrozenSmartRegion(role:"AXGroup",frame:CGRect(x:20,y:20,width:400,height:300))
        let other=FrozenSmartRegion(role:"AXButton",frame:CGRect(x:300,y:40,width:80,height:30))
        var cache=FrozenSmartSelectionCache()
        _ = cache.target(at:CGPoint(x:40,y:50),in:window,result:FrozenSmartSelectionResult(ancestry:[button,panel],siblings:[other]))
        XCTAssertEqual(cache.hierarchy(at:CGPoint(x:40,y:50),in:window).map(\.frame),[button.frame,panel.frame,window.frame])
    }
    private struct Regions:FrozenSmartSelecting {
        let value:FrozenSmartSelectionResult
        func regions(at point:CGPoint,in window:FrozenWindowCandidate,geometry:FrozenSmartGeometry) async->FrozenSmartSelectionResult{value}
    }
    func testWheelChangesActualSelectionAndPointerMovementRestoresAutomaticSelection() async throws {
        let source=try XCTUnwrap(image().cgImage(forProposedRect:nil,context:nil,hints:nil))
        let screen=CGRect(x:0,y:0,width:200,height:120)
        let window=FrozenWindowCandidate(id:1,frame:screen,ownerPID:123)
        let button=FrozenSmartRegion(role:"AXButton",frame:CGRect(x:30,y:40,width:60,height:30))
        let panel=FrozenSmartRegion(role:"AXGroup",frame:CGRect(x:20,y:20,width:150,height:90))
        let scene=FrozenSelectionView(frame:screen,image:source,screenFrame:screen,candidates:[window],smartSelector:Regions(value:FrozenSmartSelectionResult(ancestry:[button,panel])),fullScreen:{},previousArea:{},complete:{_,_ in})
        scene.refreshHover(at:CGPoint(x:40,y:50));for _ in 0..<20 {await Task.yield()}
        XCTAssertEqual(scene.selection,button.frame)
        func wheel(_ value:Int32)throws->NSEvent{try XCTUnwrap(NSEvent(cgEvent:try XCTUnwrap(CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:value,wheel2:0,wheel3:0))))}
        scene.scrollWheel(with:try wheel(5));XCTAssertEqual(scene.selection,panel.frame)
        for _ in 0..<20 {await Task.yield()};XCTAssertEqual(scene.selection,panel.frame)
        scene.scrollWheel(with:try wheel(5));XCTAssertEqual(scene.selection,screen)
        scene.scrollWheel(with:try wheel(-5));XCTAssertEqual(scene.selection,panel.frame)
        scene.refreshHover(at:CGPoint(x:46,y:50));for _ in 0..<20 {await Task.yield()}
        XCTAssertEqual(scene.selection,button.frame);scene.cancelSmartSelection()
    }
    func testAuxiliaryDisplaySwitchesAreLoadedWithoutChangingColorCopy() throws {
        let suite="SevenCaptureFlags.\(UUID().uuidString)",defaults=try XCTUnwrap(UserDefaults(suiteName:suite));defer{defaults.removePersistentDomain(forName:suite)}
        for key in [ScreenshotCapturePreferences.crosshairKey,ScreenshotCapturePreferences.hintsKey,ScreenshotCapturePreferences.magnifierKey]{defaults.set(false,forKey:key)}
        let preferences=ScreenshotCapturePreferences(defaults:defaults)
        XCTAssertFalse(preferences.crosshair);XCTAssertFalse(preferences.magnifier);XCTAssertFalse(preferences.hints)
        let source = try XCTUnwrap(image().cgImage(forProposedRect: nil, context: nil, hints: nil))
        let screen = CGRect(x: 0, y: 0, width: 200, height: 120)
        var copiedColor: String?
        var completions = 0
        let scene = FrozenSelectionView(frame: screen, image: source, screenFrame: screen, candidates: [],
            capturePreferences: preferences, fullScreen: {}, previousArea: {},
            writeColor: { copiedColor = $0; return true }, complete: { _, _ in completions += 1 })
        scene.refreshHover(at: CGPoint(x: 40, y: 50))
        scene.keyDown(with: try key("c", keyCode: 8))
        XCTAssertEqual(copiedColor, "FFFFFF")
        XCTAssertEqual(completions, 1)
    }

    func testPNGPreservesTransparencyAndJPEGFlattensToWhite() throws {
        let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:16,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        bitmap.bitmapData?.initialize(repeating:0,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
        let image=NSImage(size:CGSize(width:8,height:8));image.addRepresentation(bitmap)
        let png=try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(ScreenshotSaving.data(image,format:.png))))
        let jpeg=try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(ScreenshotSaving.data(image,format:.jpeg))))
        XCTAssertEqual(png.pixelsWide,16);XCTAssertEqual(jpeg.pixelsWide,16)
        XCTAssertEqual(try XCTUnwrap(png.colorAt(x:8,y:8)).alphaComponent,0,accuracy:0.01)
        let color=try XCTUnwrap(jpeg.colorAt(x:8,y:8)).usingColorSpace(.deviceRGB)
        XCTAssertEqual(color?.redComponent ?? 0,1,accuracy:0.02)
        XCTAssertEqual(color?.alphaComponent ?? 0,1,accuracy:0.01)
    }

}
