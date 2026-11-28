import AppKit

/// Snaps pinned image frames to physical pixel boundaries and scales resize steps with scroll-wheel magnitude.
enum ScreenshotPinGeometry {
    static func aligned(_ frame:CGRect,scale:CGFloat)->CGRect {
        let scale=max(1,scale)
        return CGRect(x:(frame.minX*scale).rounded()/scale,y:(frame.minY*scale).rounded()/scale,width:max(1,(frame.width*scale).rounded()/scale),height:max(1,(frame.height*scale).rounded()/scale))
    }
    static func nudge(keyCode:UInt16,scale:CGFloat)->CGVector? {
        let step=1/max(1,scale)
        switch keyCode {case 123:return CGVector(dx:-step,dy:0);case 124:return CGVector(dx:step,dy:0);case 125:return CGVector(dx:0,dy:-step);case 126:return CGVector(dx:0,dy:step);default:return nil}
    }
    static func scaleStep(magnitude: Int) -> Int {
        magnitude <= 5 ? 1 : magnitude <= 9 ? 5 : magnitude <= 19 ? 10 : magnitude <= 49 ? 20 : 30
    }
    static func opacityStep(magnitude: Int) -> Int {
        magnitude <= 5 ? 1 : magnitude <= 9 ? 2 : magnitude <= 29 ? 5 : magnitude <= 79 ? 10 : 30
    }
    static func resized(base: NSSize, old: NSRect, mouse: NSPoint, requestedScale: Int) -> (scale: Int, frame: NSRect) {
        var scale = requestedScale
        if scale > 400 {
            scale = 400
        } else {
            if Int(base.width * CGFloat(scale) / 100) <= 59 { scale = Int(60 / base.width * 100) }
            if Int(base.height * CGFloat(scale) / 100) <= 29 { scale = Int(30 / base.height * 100) }
        }
        // Very tall text pins can fit below 1% initially; do not round the actual scale to 0 before dividing for cursor-anchored zoom.
        let previous = old.width / base.width * 100
        let size = NSSize(width: Int(base.width * CGFloat(scale) / 100), height: Int(base.height * CGFloat(scale) / 100))
        let origin = NSPoint(x: Int(mouse.x) - Int((mouse.x - old.minX) / previous * CGFloat(scale)),
                             y: Int(mouse.y) - Int((mouse.y - old.minY) / previous * CGFloat(scale)))
        return (scale, NSRect(origin: origin, size: size))
    }
}

/// Preserves the original pinned image; corner radius, opacity, and shadow apply only to the floating display.
@MainActor final class ScreenshotPinWindowController: NSWindowController, NSWindowDelegate {
    let originalImage: NSImage
    private(set) var annotationDocument=ScreenshotEditorDocument()
    private var renderedImage:NSImage
    var currentImage:NSImage {renderedImage}
    private var sharing:ScreenshotSharingSession?
    private var shadowPanel:NSPanel?
    private weak var activeEditor:ScreenshotEditorWindowController?
    private let closeShortcut:HotKeyManager
    private let closeAllShortcut:HotKeyManager
    private let toolbarPreferences:ScreenshotToolbarPreferences
    private let savePreferences:ScreenshotSavePreferences
    private(set) var isClosed = false
    var onAnnotate: ((NSImage) -> Void)?
    var onOCR: ((NSImage) -> Void)?
    var onCloseAll: (() -> Void)?
    init(image: NSImage, preferences: ScreenshotPinPreferences = ScreenshotPinPreferences(defaults: .standard), onAnnotate: ((NSImage) -> Void)? = nil, toolbarPreferences:ScreenshotToolbarPreferences? = nil, savePreferences:ScreenshotSavePreferences? = nil,closeShortcut:HotKeyManager? = nil,closeAllShortcut:HotKeyManager? = nil) {
        self.closeShortcut=closeShortcut ?? ScreenshotPinShortcuts.closeCurrent(defaults:preferences.shortcutDefaults)
        self.closeAllShortcut=closeAllShortcut ?? ScreenshotPinShortcuts.closeAll(defaults:preferences.shortcutDefaults)
        originalImage = image; renderedImage=image; self.onAnnotate = onAnnotate
        self.toolbarPreferences=toolbarPreferences ?? (preferences.usesPersistentStorage ? .shared:ScreenshotToolbarPreferences())
        self.savePreferences=savePreferences ?? ScreenshotSavePreferences(defaults:preferences.usesPersistentStorage ? .standard:nil)
        let window = ScreenshotPinPanel(contentRect: CGRect(origin: .zero, size: image.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = L10n.text("pinnedScreenshot"); window.isReleasedWhenClosed = false
        window.isOpaque = false; window.backgroundColor = ThemePalette.clear
        window.hidesOnDeactivate = false; window.animationBehavior = .none
        window.hasShadow = false; window.level = NSWindow.Level(rawValue: 25)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        let view = ScreenshotPinnedImageView(image: image, preferences: preferences, toolbarPreferences:self.toolbarPreferences,closeShortcut:self.closeShortcut,closeAllShortcut:self.closeAllShortcut)
        view.autoresizingMask = [.width, .height]; window.contentView = view
        super.init(window: window); window.delegate = self
        view.onAnnotate = { [weak self] in guard let self,!self.isClosed else{return};self.onAnnotate?(self.currentImage) }; window.onAnnotate = view.onAnnotate
        window.onKey = { [weak self] in self?.handleKey($0) ?? false }
        view.onShare = { [weak self,weak view] in
            guard let self,let view else{return}
            ScreenshotSharingSession.present(self.currentImage,from:view,current:&self.sharing)
        }
        view.onCopy = { [weak self] in self?.copyImage() }
        view.onSave = { [weak self] in self?.saveImage() }
        view.onFrameChange = { [weak self] frame in self?.setContentFrame(frame) }
        view.onShadowChanged = { [weak self] in self?.updateShadow() }
        view.onOCR = { [weak self] in guard let self else{return};self.onOCR?(self.currentImage) }
        view.onClose = { [weak self] in self?.close() }
        view.onCloseAll = { [weak self] in self?.onCloseAll?() }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            let factor = min(1, (area.width-Design.Space.l*2)/max(1,image.size.width), (area.height-Design.Space.l*2)/max(1,image.size.height))
            let size = CGSize(width: max(1,image.size.width*factor),height: max(1,image.size.height*factor))
            setContentFrame(ScreenshotPinGeometry.aligned(CGRect(x:area.midX-size.width/2,y:area.midY-size.height/2,width:size.width,height:size.height),scale:screen?.backingScaleFactor ?? 1))
            view.scalePercent = max(1,Int(factor*100))
        } else { window.center() }
    }
    required init?(coder: NSCoder) { nil }
    override func showWindow(_ sender:Any?) {super.showWindow(sender);updateShadow()}
    override func close() { isClosed = true; activeEditor?.close();closeShadow();super.close() }
    func windowWillClose(_ notification: Notification) { isClosed = true;activeEditor?.close();closeShadow() }
    func windowDidMove(_ notification:Notification){updateShadow()}
    func windowDidResize(_ notification:Notification){updateShadow()}
    private func closeShadow(){if let shadowPanel {window?.removeChildWindow(shadowPanel);shadowPanel.close();self.shadowPanel=nil}}
    func refreshInterfaceLanguage() {
        window?.title = L10n.text("pinnedScreenshot")
        shadowPanel?.title = L10n.text("pinShadow")
        (window?.contentView as? ScreenshotPinnedImageView)?.refreshInterfaceLanguage()
        activeEditor?.refreshInterfaceLanguage()
    }

    private func updateShadow(){
        guard !isClosed,let window,window.isVisible,let view=window.contentView as? ScreenshotPinnedImageView,!view.isEditing,view.shadowStyle.effective,let image=view.image else{shadowPanel?.orderOut(nil);return}
        let panel:NSPanel
        if let existing=shadowPanel {panel=existing}
        else {
            panel=NSPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.title=L10n.text("pinShadow");panel.isReleasedWhenClosed=false;panel.ignoresMouseEvents=true;panel.hasShadow=false
            panel.isOpaque=false;panel.backgroundColor=ThemePalette.clear;panel.hidesOnDeactivate=false
            panel.animationBehavior = .none;panel.collectionBehavior=window.collectionBehavior;panel.level=window.level
            panel.contentView=ScreenshotPinShadowView();shadowPanel=panel
        }
        let body=contentFrame,frame=body.insetBy(dx:-view.shadowStyle.inset,dy:-view.shadowStyle.inset).integral
        panel.setFrame(frame,display:false)
        if let shadow=panel.contentView as? ScreenshotPinShadowView {
            shadow.image=image;shadow.imageRect=body.offsetBy(dx:-frame.minX,dy:-frame.minY)
            shadow.style=view.shadowStyle;shadow.needsDisplay=true
        }
        if panel.parent !== window {window.addChildWindow(panel,ordered:.below)}
        panel.order(.below,relativeTo:window.windowNumber)
    }
    var editingContext: ScreenshotCenteredEditorContext? {
        guard let frame = window?.screen?.frame ?? NSScreen.main?.frame else { return nil }
        // Editing an existing image does not need to recapture the screen or request Screen Recording permission.
        return ScreenshotCenteredEditorContext(screenFrame:frame,background:nil,placement:contentFrame)
    }
    var contentFrame:CGRect {
        guard let window,let view=window.contentView as? ScreenshotPinnedImageView else{return .zero}
        return window.convertToScreen(view.convert(view.imageRect,to:nil))
    }
    private func setContentFrame(_ frame:CGRect) {
        guard let window,let view=window.contentView as? ScreenshotPinnedImageView else{return}
        let inset=Design.ScreenshotPin.drawingInset
        let outer=CGRect(x:floor(frame.minX)-inset,y:floor(frame.minY)-inset,width:ceil(frame.maxX)-floor(frame.minX)+inset*2,height:ceil(frame.maxY)-floor(frame.minY)+inset*2)
        window.setFrame(outer,display:false)
        view.imageRect=frame.offsetBy(dx:-outer.minX,dy:-outer.minY)
        window.displayIfNeeded();updateShadow()
    }
    func copyImage(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents(); pasteboard.writeObjects([currentImage])
    }
    func pngData() -> Data? {ScreenshotSaving.data(currentImage,format:.png)}
    private func saveImage() { ScreenshotSaving.save(currentImage,parent:window,preferences:savePreferences,completed:{}) }
    func makeEditor(preferences:ScreenshotToolPreferences = ScreenshotToolPreferences(defaults:.standard),clipboardWriter:((NSImage)->Bool)? = nil)->ScreenshotEditorWindowController? {
        guard !isClosed,activeEditor==nil,let context=editingContext,let view=window?.contentView as? ScreenshotPinnedImageView else{return nil}
        let editor=ScreenshotEditorWindowController(image:originalImage,context: .centered(context),preferences:preferences,pinDocument:annotationDocument,toolbarPreferences:toolbarPreferences,savePreferences:savePreferences,clipboardWriter:clipboardWriter)
        editor.sharingCompanionWindow=window
        activeEditor=editor;view.isEditing=true
        editor.onPinUpdate={ [weak self] image,document in
            guard let self,!self.isClosed else{return}
            self.annotationDocument=document;self.renderedImage=image
        }
        editor.onEditingEnded={ [weak self,weak view] in
            guard let self else{return}
            view?.image=self.currentImage;view?.isEditing=false;self.activeEditor=nil
            if !self.isClosed,self.window?.isVisible == true {self.window?.makeKey()}
        }
        return editor
    }
    func setVisible(_ visible:Bool) {
        guard !isClosed else{return}
        if visible {window?.orderFrontRegardless();updateShadow()}else{activeEditor?.close();shadowPanel?.orderOut(nil);window?.orderOut(nil)}
    }
    @discardableResult func handleKey(_ event:NSEvent)->Bool {
        guard !isClosed,let window else{return false}
        if let movement=ScreenshotPinGeometry.nudge(keyCode:event.keyCode,scale:window.screen?.backingScaleFactor ?? 1),event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty {
            setContentFrame(contentFrame.offsetBy(dx:movement.dx,dy:movement.dy));return true
        }
        let view=window.contentView as? ScreenshotPinnedImageView
        if closeShortcut.matches(event) {if !event.isARepeat {close()};return true}
        if closeAllShortcut.matches(event) {if !event.isARepeat {onCloseAll?()};return true}
        if event.isARepeat {return true}
        if event.modifierFlags.contains(.command),event.keyCode==8 {copyImage();return true}
        if event.modifierFlags.contains(.command),event.keyCode==1 {saveImage();return true}
        guard let action=toolbarPreferences.action(for:event,context:.pinIdle) else{return false}
        switch action {
        case .edit:onAnnotate?(currentImage)
        case .copy:copyImage()
        case .share:view?.onShare?()
        case .save:saveImage()
        case .ocr:onOCR?(currentImage)
        default:return false
        }
        return true
    }
}

private final class ScreenshotPinPanel: NSPanel {
    var onAnnotate: (() -> Void)?
    var onKey: ((NSEvent)->Bool)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event)==true {return}
        if event.keyCode == 53 || (event.keyCode == 13 && event.modifierFlags.contains(.command)) { close() }
        else if event.keyCode == 49 { onAnnotate?() }
        else { super.keyDown(with: event) }
    }
}

final class ScreenshotPinnedImageView: ThemedDrawingView, NSMenuDelegate {
    var image:NSImage? {didSet{needsDisplay=true;onShadowChanged?()}}
    var isEditing=false {didSet{closeButton.isHidden=true;needsDisplay=true;onShadowChanged?()}}
    var imageRect:CGRect = .zero {didSet{updateClosePosition();needsDisplay=true}}
    var shadowStyle:ScreenshotShadowStyle
    var onShadowChanged:(()->Void)?
    var onFrameChange:((CGRect)->Void)?
    private var closeLeading:NSLayoutConstraint?
    private var closeTop:NSLayoutConstraint?
    var onAnnotate: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onShare:(()->Void)?
    var onOCR: (() -> Void)?
    var onClose: (() -> Void)?
    var onCloseAll: (() -> Void)?
    var scalePercent = 100
    private let baseSize: NSSize
    private let preferences: ScreenshotPinPreferences
    private let closeShortcut:HotKeyManager
    private let closeAllShortcut:HotKeyManager
    private let toolbarPreferences: ScreenshotToolbarPreferences
    private(set) var displayOpacity: CGFloat
    private let closeButton = NSButton()
    func refreshInterfaceLanguage() {
        setAccessibilityLabel(L10n.text("pinnedImageDragToMoveItOr"))
        closeButton.updateLocalizedLabel(L10n.text("closePin"))
    }

    private var tracking: NSTrackingArea?
    init(image: NSImage, preferences: ScreenshotPinPreferences,toolbarPreferences:ScreenshotToolbarPreferences,closeShortcut:HotKeyManager,closeAllShortcut:HotKeyManager) {
        self.closeShortcut=closeShortcut;self.closeAllShortcut=closeAllShortcut
        baseSize = image.size; self.preferences = preferences;self.toolbarPreferences=toolbarPreferences
        shadowStyle=preferences.shadowStyle
        displayOpacity = 1
        super.init(frame: CGRect(origin:.zero,size:image.size)); self.image = image;imageRect=bounds
        focusRingType = .none
        setAccessibilityRole(.group); setAccessibilityLabel(L10n.text("pinnedImageDragToMoveItOr"))
        closeButton.imagePosition = .imageOnly; closeButton.isBordered = false; closeButton.focusRingType = .none
        closeButton.target = self; closeButton.action = #selector(closePin); closeButton.isHidden = true
        closeButton.toolTip = L10n.text("closePin"); closeButton.setAccessibilityLabel(L10n.text("closePin"))
        closeButton.translatesAutoresizingMaskIntoConstraints = false; addSubview(closeButton)
        let leading=closeButton.leadingAnchor.constraint(equalTo:leadingAnchor,constant:Design.ScreenshotPin.closeInset)
        let top=closeButton.topAnchor.constraint(equalTo:topAnchor,constant:Design.ScreenshotPin.closeInset)
        closeLeading=leading;closeTop=top
        NSLayoutConstraint.activate([
            leading,top,
            closeButton.widthAnchor.constraint(equalToConstant:Design.ScreenshotPin.closeSize),
            closeButton.heightAnchor.constraint(equalToConstant:Design.ScreenshotPin.closeSize)
        ])
        applyTheme(ThemeManager.shared.palette)
    }
    override func applyTheme(_ palette: ThemePalette) {
        super.applyTheme(palette)
        closeButton.image = Design.Icon.symbol("xmark.circle.fill",description:L10n.text("closePin"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:Design.ScreenshotPin.closeSymbolSize,weight:.regular))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors:[palette.pinCloseInk,palette.pinCloseFill]))
    }

    required init?(coder:NSCoder){nil}
    private func updateClosePosition() {
        closeLeading?.constant=imageRect.minX+Design.ScreenshotPin.closeInset
        closeTop?.constant=bounds.maxY-imageRect.maxY+Design.ScreenshotPin.closeInset
    }
    override func setFrameSize(_ newSize:NSSize) {
        super.setFrameSize(newSize)
        imageRect=CGRect(origin:.zero,size:newSize).insetBy(dx:Design.ScreenshotPin.drawingInset,dy:Design.ScreenshotPin.drawingInset)
    }
    override var mouseDownCanMoveWindow: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        ThemePalette.clear.setFill();dirtyRect.fill(using:.copy)
        guard !isEditing else{return}
        NSGraphicsContext.saveGraphicsState()
        image?.draw(in:imageRect,from:.zero,operation:.sourceOver,fraction:displayOpacity,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event:NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event:NSEvent) { closeButton.isHidden = true }
    override func scrollWheel(with event: NSEvent) {
        let delta = Float(event.deltaY)
        guard delta != 0, let window else { return }
        let magnitude = abs(Int(event.cgEvent?.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) ?? event.deltaY))
        let sign = delta > 0 ? 1 : -1
        if preferences.opacityWheel.matches(event.modifierFlags) {
            let step = ScreenshotPinGeometry.opacityStep(magnitude:magnitude)
            displayOpacity = min(1,max(Design.ScreenshotEditor.minimumPinOpacity,displayOpacity+CGFloat(sign*step)/100))
            needsDisplay = true; window.invalidateShadow(); return
        }
        guard preferences.zoomWheel.matches(event.modifierFlags) else { return }
        let step = ScreenshotPinGeometry.scaleStep(magnitude:magnitude)
        let old=window.convertToScreen(convert(imageRect,to:nil))
        let resized = ScreenshotPinGeometry.resized(base:baseSize,old:old,mouse:NSEvent.mouseLocation,requestedScale:scalePercent+sign*step)
        scalePercent = resized.scale;onFrameChange?(resized.frame)
    }
    override func accessibilityChildren() -> [Any]? { closeButton.isHidden ? [] : [closeButton] }
    override func mouseDown(with event:NSEvent) {
        window?.makeKey();closeButton.isHidden = false
        if event.clickCount == 2 { onClose?() } else { super.mouseDown(with:event) }
    }
    override func menu(for event:NSEvent)->NSMenu? {
        let menu=NSMenu();menu.autoenablesItems=false;menu.delegate=self
        func add(_ title:String,_ hint:String,_ action:Selector) {
            let item=menu.addItem(withTitle:title,action:action,keyEquivalent:"");item.target=self
            let paragraph=NSMutableParagraphStyle();paragraph.tabStops=[NSTextTab(textAlignment:.right,location:Design.ScreenshotPin.menuHintPosition)]
            let value=NSMutableAttributedString(string:title+"\t"+hint,attributes:[.font:Design.ScreenshotPin.menuFont,.paragraphStyle:paragraph])
            value.addAttributes([.font:Design.Text.note.nsFont,.foregroundColor:theme.inkSecondary],range:NSRange(location:(title as NSString).length+1,length:(hint as NSString).length))
            item.attributedTitle=value
        }
        for (title,kind,action,fallback) in [(L10n.text("edit"),ScreenshotToolbarAction.edit,#selector(annotateImage),"Space"),(L10n.text("copy"),.copy,#selector(copyImage),"⌘C"),(L10n.text("save"),.save,#selector(saveImage),"⌘S"),("OCR",.ocr,#selector(ocrImage),""),(L10n.text("share"),.share,#selector(shareImage),"")] {
            let key=kind == .copy ? fallback:toolbarPreferences.hint(kind);add(title,key.isEmpty ? fallback:key,action)
        }
        menu.addItem(.separator())
        add(L10n.text("zoom"),preferences.zoomWheel.title,#selector(dismissHint))
        add(L10n.text("opacity"),preferences.opacityWheel.title,#selector(dismissHint))
        menu.addItem(.separator())
        let closeKey=closeShortcut.isEnabled ? closeShortcut.shortcut.displayName:"Esc"
        add(L10n.text("closePin"),closeKey,#selector(closePin))
        add(L10n.text("closeAllPins"),closeAllShortcut.isEnabled ? closeAllShortcut.shortcut.displayName:"",#selector(closeAllPins))
        return menu
    }
    func menu(_ menu:NSMenu,willHighlight selected:NSMenuItem?) {
        for item in menu.items {
            guard let original=item.attributedTitle else{continue}
            let value=NSMutableAttributedString(attributedString:original),string=original.string as NSString,tab=string.range(of:"\t")
            guard tab.location != NSNotFound else{continue}
            value.removeAttribute(.foregroundColor,range:NSRange(location:0,length:string.length))
            if item === selected {value.addAttribute(.foregroundColor,value:theme.menuSelectedText,range:NSRange(location:0,length:string.length))}
            else {value.addAttribute(.foregroundColor,value:theme.inkSecondary,range:NSRange(location:tab.location+1,length:string.length-tab.location-1))}
            item.attributedTitle=value
        }
    }
    @objc private func dismissHint() {}
    @objc private func copyImage(){onCopy?()}
    @objc private func annotateImage(){onAnnotate?()}
    @objc private func saveImage(){onSave?()}
    @objc private func ocrImage(){onOCR?()}
    @objc private func shareImage(){onShare?()}
    @objc private func closePin(){onClose?()}
    @objc private func closeAllPins(){onCloseAll?()}
}
