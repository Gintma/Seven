import AppKit

/// 所有颜色入口共用原生快捷色板，再由“显示颜色”进入系统调色板。
final class ColorSelectionWell: NSColorWell, ThemeApplying {
    private var palette = ThemePalette.system

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        needsDisplay = true
    }

    private static weak var owner:ColorSelectionWell?
    private var panelState:(level:NSWindow.Level,hides:Bool,behavior:NSWindow.CollectionBehavior)?
    private var presentedPanel=false
    private var observers:[NSObjectProtocol]=[]
    var onColorChange:((NSColor)->Void)?
    var onEditingBegan:(()->Void)?
    var onEditingEnded:(()->Void)?
    override init(frame:NSRect) {
        super.init(frame:frame);focusRingType = .none;colorWellStyle = .minimal
        ThemeManager.shared.register(self)
        for name in [NSWindow.didBecomeKeyNotification,NSWindow.didUpdateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:NSColorPanel.shared,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {self?.correctPanelPresentation()}
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:NSColorPanel.shared,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {guard let self,Self.owner === self else{return};self.onEditingEnded?();self.restorePanelState()}
        })
    }
    required init?(coder:NSCoder){nil}
    deinit {observers.forEach(NotificationCenter.default.removeObserver)}
    override var color:NSColor {didSet{needsDisplay=true;onColorChange?(color)}}
    override var needsPanelToBecomeKey:Bool {true}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();if window == nil {dismissSelection()}}
    private func preparePanel() {
        if Self.owner !== self {Self.owner?.dismissSelection()}
        Self.owner=self
        let panel=NSColorPanel.shared
        if panelState == nil {panelState=(panel.level,panel.hidesOnDeactivate,panel.collectionBehavior)}
        panel.hidesOnDeactivate=false
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.level=NSWindow.Level(rawValue:max(NSWindow.Level.floating.rawValue,(window?.level.rawValue ?? 0)+2))
    }
    func correctPanelPresentation() {
        guard Self.owner === self,NSColorPanel.shared.isVisible else{return}
        let expected=NSWindow.Level(rawValue:max(NSWindow.Level.floating.rawValue,(window?.level.rawValue ?? 0)+2))
        if NSColorPanel.shared.level != expected {NSColorPanel.shared.level=expected;NSColorPanel.shared.orderFrontRegardless()}
        if !presentedPanel {presentedPanel=true;NSColorPanel.shared.makeKeyAndOrderFront(nil);NSColorPanel.shared.orderFrontRegardless()}
    }
    override func mouseDown(with event:NSEvent) {
        window?.makeKey();preparePanel();onEditingBegan?();super.mouseDown(with:event)
    }
    override func activate(_ exclusive:Bool) {preparePanel();super.activate(exclusive);correctPanelPresentation()}
    override func deactivate() {super.deactivate();onEditingEnded?()}
    func dismissSelection() {
        guard Self.owner === self else{return}
        deactivate();NSColorPanel.shared.orderOut(nil);restorePanelState()
    }
    private func restorePanelState() {
        guard Self.owner === self else{return}
        if let state=panelState {
            NSColorPanel.shared.level=state.level;NSColorPanel.shared.hidesOnDeactivate=state.hides
            NSColorPanel.shared.collectionBehavior=state.behavior
        }
        panelState=nil;presentedPanel=false;Self.owner=nil
    }
    override func draw(_ dirtyRect:NSRect) {
        let side=min(Design.ScreenshotEditor.toolbarSwatchSize,bounds.width,bounds.height)
        let circle=NSBezierPath(ovalIn:CGRect(x:bounds.midX-side/2,y:bounds.midY-side/2,width:side,height:side))
        color.setFill();circle.fill();palette.toolbarSwatchBorder.setStroke()
        circle.lineWidth=Design.ScreenshotEditor.toolbarGlyphLineWidth;circle.stroke()
    }
}

/// 编辑层压住普通应用和菜单栏，但必须低于系统原生 popover（而非 screenSaver 层级）。
enum ScreenshotPresentation {
    static let overlayLevel:NSWindow.Level = .statusBar
}
