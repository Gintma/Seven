import AppKit

@MainActor final class ScreenshotEditorWindowController: NSWindowController, NSWindowDelegate {
    var onPin: ((NSImage)->Void)?
    var onOCR: ((NSImage)->Void)?
    var onScroll: ((NSImage)->Void)? { didSet { updateControls() } }
    var onExportSuccess: (()->Void)?
    var onPinUpdate: ((NSImage,ScreenshotEditorDocument)->Void)?
    var onEditingEnded: (()->Void)?
    weak var sharingCompanionWindow:NSWindow?
    private var sharing:ScreenshotSharingSession?
    private var previewShadow:ScreenshotPinShadowView?
    private let shadowStyle:ScreenshotShadowStyle
    private let isPinEditing:Bool
    private let toolbarPreferences:ScreenshotToolbarPreferences
    private let capturePreferences:ScreenshotCapturePreferences
    private let soundPlayer:()->Void
    private var playedCompletionSound=false
    private let clipboardWriter:(NSImage)->Bool
    private let savePreferences:ScreenshotSavePreferences
    private var editingFinished=false
    private var keyboardMonitor:Any?
    private var actionButtons:[ScreenshotToolbarAction:NSButton]=[:]

    private var centeredOverlay: ScreenshotCenteredEditorOverlay?
    private var selectionOverlay: ScreenshotEditorSelectionOverlay?
    private var toolbarPanel: NSPanel?
    private var sizePanel: NSPanel?
    private let dragButton = ScreenshotToolbarDragButton()
    private let sizeToolbar = ScreenshotSelectionSizeToolbar()
    private var toolbarDragStart: CGPoint?
    private var manualToolbarTopLeft: CGPoint?
    private var colorPanelObservers: [NSObjectProtocol] = []
    var captureRect: CGRect? { selectionOverlay?.globalSelection }
    private let canvas: ScreenshotEditorCanvas
    private var toolButtons: [NSButton] = []
    private let widthControl = ScreenshotValueSlider(value: 3, min: 1, max: 40)
    private let markerStyle = SlidingSegmentedControl(frame: .zero)
    private let textStyleMenu = SlidingSegmentedControl(frame: .zero)
    private let focusShape = SlidingSegmentedControl(frame: .zero)
    private let toolbarUI = ScreenshotEditorToolbar()
    private let colorWell = ColorSelectionWell(frame: .zero)
    private let scrollButton = ScreenshotToolbarButton(symbol: "rectangle.arrowtriangle.2.outward", title: L10n.text("scrollingScreenshot"), target: nil, action: nil)
    private let shapeMode = SlidingSegmentedControl(frame: .zero)
    private let arrowStyle = SlidingSegmentedControl(frame: .zero)
    private let pencilMode = SlidingSegmentedControl(frame: .zero)
    private let lineStyle = SlidingSegmentedControl(frame: .zero)
    private let cornerControl = ScreenshotValueSlider(value: Double(Design.ScreenshotEditor.defaultCornerRadius), min: 0, max: Double(Design.ScreenshotEditor.maximumCornerRadius))
    private var cornerOption: NSView?
    private let mosaicMode = SlidingSegmentedControl(frame: .zero)
    private let arrowPath = SlidingSegmentedControl(frame: .zero)
    private var widthOption: NSStackView?
    private var textStyleOption: NSView?
    private var opacityOption: NSView?
    private let preferences: ScreenshotToolPreferences
    private var synchronizingToolControls = false
    private let opacityControl = ScreenshotValueSlider(value: 1, min: 0, max: 1)
    private let undoButton = ScreenshotToolbarButton(symbol: "arrow.uturn.backward", title: L10n.text("undo"), target: nil, action: nil)
    private let redoButton = ScreenshotToolbarButton(symbol: "arrow.uturn.forward", title: L10n.text("redo"), target: nil, action: nil)
    enum Context {
        case selection(FrozenSelectionContext)
        case centered(ScreenshotCenteredEditorContext)

        var screenFrame: CGRect {
            switch self {
            case .selection(let context): return context.screenFrame
            case .centered(let context): return context.screenFrame
            }
        }
    }

    init(image:NSImage, context: Context, preferences: ScreenshotToolPreferences = ScreenshotToolPreferences(defaults: .standard), pinDocument:ScreenshotEditorDocument? = nil, toolbarPreferences:ScreenshotToolbarPreferences? = nil, savePreferences:ScreenshotSavePreferences? = nil,clipboardWriter:((NSImage)->Bool)? = nil,soundPlayer:(()->Void)? = nil) {
        self.soundPlayer=soundPlayer ?? (preferences.usesPersistentStorage ? {ScreenshotCompletionSound.play()} : {})
        self.clipboardWriter=clipboardWriter ?? {image in NSPasteboard.general.clearContents();return NSPasteboard.general.writeObjects([image])}
        self.preferences = preferences
        isPinEditing=pinDocument != nil
        shadowStyle=preferences.shadowStyle
        self.toolbarPreferences=toolbarPreferences ?? (preferences.usesPersistentStorage ? .shared:ScreenshotToolbarPreferences())
        self.capturePreferences=preferences.capturePreferences
        self.savePreferences=savePreferences ?? ScreenshotSavePreferences(defaults:preferences.usesPersistentStorage ? .standard:nil)
        let displayImage: NSImage
        if case .centered(let centeredContext) = context, centeredContext.placement == nil, let copy = image.copy() as? NSImage {
            copy.size = centeredContext.displayedSize(for: image); displayImage = copy
        } else { displayImage = image }
        canvas=ScreenshotEditorCanvas(image:displayImage)
        canvas.outputCornerRadius = pinDocument == nil ? preferences.outputCornerRadius:0
        if let pinDocument { canvas.document=pinDocument }

        let view = NSView()
        let toolbar = toolbarUI.primary
        let options = toolbarUI.options
        let root = NSStackView(views: [toolbarUI])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = Design.Space.s
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let window = ScreenshotEditorOverlayPanel(contentRect: context.screenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = ScreenshotPresentation.overlayLevel; window.hasShadow = false
        window.isOpaque = false; window.backgroundColor = ThemePalette.clear
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        switch context {
        case .selection(let selectionContext):
            let overlay = ScreenshotEditorSelectionOverlay(context: selectionContext, canvas: canvas)
            selectionOverlay = overlay; window.contentView = overlay
        case .centered(let centeredContext):
            let overlay = ScreenshotCenteredEditorOverlay(context: centeredContext, canvas: canvas)
            centeredOverlay = overlay; window.contentView = overlay
        }

        let tools = ScreenshotEditorToolsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        tools.isReleasedWhenClosed = false
        tools.becomesKeyOnlyIfNeeded = true
        tools.title = L10n.text("screenshotToolbar")
        tools.animationBehavior = .none
        tools.isOpaque = false
        tools.backgroundColor = ThemePalette.clear
        tools.hasShadow = false
        tools.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        tools.contentView = view
        toolbarPanel = tools
        window.addChildWindow(tools, ordered: .above)
        if case .selection = context {
            let dimensions = ScreenshotEditorToolsPanel(contentRect: CGRect(origin: .zero, size: sizeToolbar.fittingSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            dimensions.isReleasedWhenClosed = false; dimensions.becomesKeyOnlyIfNeeded = true
            dimensions.title = L10n.text("screenshotDimensions"); dimensions.animationBehavior = .none
            dimensions.isOpaque = false; dimensions.backgroundColor = ThemePalette.clear
            dimensions.hasShadow = false; dimensions.level = tools.level
            dimensions.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            dimensions.contentView = sizeToolbar; sizePanel = dimensions
            window.addChildWindow(dimensions, ordered: .above)
        }
        window.title=L10n.text("screenshotEditor");window.isReleasedWhenClosed=false;window.acceptsMouseMovedEvents=true
        super.init(window:window)
        window.delegate = self
        if !isPinEditing,shadowStyle.effective,let parent=canvas.superview {
            let shadow=ScreenshotPinShadowView();shadow.wantsLayer=true;shadow.autoresizingMask=[.width,.height]
            parent.addSubview(shadow,positioned:.below,relativeTo:canvas);previewShadow=shadow
        }
        for tool in ScreenshotEditorTool.toolbarCases {
            let button = ScreenshotToolbarButton(symbol: tool.symbol, title: tool.title, target: self, action: #selector(selectTool(_:)))
            button.setButtonType(.pushOnPushOff)
            button.tag = tool.rawValue
            toolbar.addArrangedSubview(button)
            toolButtons.append(button)
        }
        for button in toolButtons {
            if let tool=ScreenshotEditorTool(rawValue:button.tag),let action=ScreenshotToolbarAction(rawValue:String(describing:tool)) {actionButtons[action]=button}
        }
        colorWell.colorWellStyle = .minimal
        colorWell.color = Design.ScreenshotEditor.defaultStrokeColor
        colorWell.onEditingBegan = { [weak self] in
            self?.canvas.endParameterChange(); self?.canvas.beginParameterChange()
        }
        colorWell.onEditingEnded = { [weak self] in self?.canvas.endParameterChange() }
        for slider in [widthControl, opacityControl, cornerControl] {
            slider.onEditingBegan = { [weak self] in self?.dismissColorPanel(); self?.canvas.beginParameterChange() }
            slider.onEditingEnded = { [weak self] in self?.canvas.endParameterChange() }
        }
        colorWell.onColorChange = { [weak self] color in
            guard let self, !self.synchronizingToolControls, color != self.canvas.color else { return }
            self.canvas.beginParameterChange()
            self.canvas.color = color
            self.canvas.updateSelected { $0.color = color }
            self.saveToolOptions()
        }
        colorWell.setAccessibilityLabel(L10n.text("annotationColor")); colorWell.toolTip = L10n.text("annotationColor")
        colorWell.widthAnchor.constraint(equalToConstant: Design.ScreenshotEditor.toolbarControlHeight).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: Design.ScreenshotEditor.toolbarControlHeight).isActive = true
        markerStyle.segmentCount = 3; markerStyle.trackingMode = .selectOne
        markerStyle.target = self; markerStyle.action = #selector(changeMarker(_:)); markerStyle.setAccessibilityLabel(L10n.text("marker"))
        for marker in ScreenshotAnnotationMarker.allCases {
            markerStyle.setImage(Design.Icon.symbol(marker.symbol, description: marker.title), forSegment: marker.rawValue)
            markerStyle.setToolTip(marker.title, forSegment: marker.rawValue)
            markerStyle.setWidth(Design.ScreenshotEditor.toolbarOptionSegmentWidth, forSegment: marker.rawValue)
        }
        textStyleMenu.imageSize = Design.Segmented.textStyleIconSize
        textStyleMenu.segmentCount = 3; textStyleMenu.trackingMode = .selectOne
        textStyleMenu.target = self; textStyleMenu.action = #selector(changeTextStyle(_:)); textStyleMenu.setAccessibilityLabel(L10n.text("textStyle"))
        for (index, style) in ScreenshotEditorTextStyle.toolbarCases.enumerated() {
            textStyleMenu.setImage(ScreenshotToolbarSymbols.text(style), forSegment: index)
            textStyleMenu.setImageDecoration(style == .background ? .filled : style == .outline ? .outlined : .none, forSegment: index)
            textStyleMenu.setToolTip(style == .plain ? L10n.text("plainText") : style.title, forSegment: index)
            textStyleMenu.setWidth(Design.Segmented.textStyleSegmentWidth, forSegment: index)
        }
        focusShape.segmentCount = 2; focusShape.trackingMode = .selectOne
        focusShape.target = self; focusShape.action = #selector(changeFocusShape(_:)); focusShape.setAccessibilityLabel(L10n.text("spotlightShape"))
        for index in 0..<2 {
            focusShape.setImage(ScreenshotToolbarSymbols.shape(.outline, ellipse: index == 1), forSegment: index)
            focusShape.setToolTip(index == 0 ? L10n.text("rectangularSpotlight") : L10n.text("ellipticalSpotlight"), forSegment: index)
            focusShape.setWidth(Design.ScreenshotEditor.toolbarOptionSegmentWidth, forSegment: index)
        }
        arrowStyle.segmentCount = ScreenshotArrowStyle.allCases.count; arrowStyle.trackingMode = .selectOne
        arrowStyle.target = self; arrowStyle.action = #selector(changeArrowStyle(_:)); arrowStyle.setAccessibilityLabel(L10n.text("arrowStyle"))
        for (index, style) in ScreenshotArrowStyle.allCases.enumerated() {
            arrowStyle.setImage(ScreenshotToolbarSymbols.arrow(style), forSegment: index)
            arrowStyle.setToolTip(style.title, forSegment: index)
        }
        arrowPath.segmentCount = 2; arrowPath.trackingMode = .selectOne
        arrowPath.target = self; arrowPath.action = #selector(changeArrowPath(_:)); arrowPath.setAccessibilityLabel(L10n.text("arrowPath"))
        for (index, symbol) in ["line.diagonal", "alternatingcurrent"].enumerated() {
            arrowPath.setImage(Design.Icon.symbol(symbol, description: index == 0 ? L10n.text("straightLine") : L10n.text("curvedLine")), forSegment: index)
            arrowPath.setToolTip(index == 0 ? L10n.text("straightLine") : L10n.text("curvedLine"), forSegment: index)
        }
        pencilMode.segmentCount = 2; pencilMode.trackingMode = .selectOne
        pencilMode.target = self; pencilMode.action = #selector(changePencilMode(_:)); pencilMode.setAccessibilityLabel(L10n.text("penMode"))
        for (index, mode) in ScreenshotPencilMode.toolbarCases.enumerated() {
            pencilMode.setImage(Design.Icon.symbol(mode.symbol, description: mode.title), forSegment: index)
            pencilMode.setToolTip(mode.title, forSegment: index)
        }
        let widths = widthControl
        widths.target=self;widths.action=#selector(changeWidth(_:));widths.setAccessibilityLabel(L10n.text("annotationThickness"))
        let opacity = opacityControl
        opacity.target = self; opacity.action = #selector(changeOpacity(_:)); opacity.setAccessibilityLabel(L10n.text("annotationOpacity"))
        mosaicMode.segmentCount = 2; mosaicMode.trackingMode = .selectOne
        mosaicMode.target = self; mosaicMode.action = #selector(changeMosaicMode(_:)); mosaicMode.setAccessibilityLabel(L10n.text("redactionMode"))
        for (index, symbol) in [Design.Icon.screenshotMosaic, "aqi.medium"].enumerated() {
            mosaicMode.setImage(Design.Icon.symbol(symbol, description: index == 0 ? L10n.text("pixelate") : L10n.text("gaussianBlur")), forSegment: index)
            mosaicMode.setToolTip(index == 0 ? L10n.text("pixelate") : L10n.text("gaussianBlur"), forSegment: index)
        }
        widths.widthAnchor.constraint(equalToConstant: Design.ScreenshotEditor.toolbarSliderWidth).isActive = true
        opacity.widthAnchor.constraint(equalToConstant: Design.ScreenshotEditor.toolbarSliderWidth).isActive = true
        widthOption = NSStackView(views: [widths])
        textStyleOption = textStyleMenu
        opacityOption = opacity
        opacity.toolTip = L10n.text("opacity")
        opacity.formatValue = { L10n.format("opacity2", String(describing: Int($0 * 100))) }
        cornerControl.formatValue = { L10n.format("cornerRadiusPt", String(describing: Int($0))) }
        options.addArrangedSubview(colorWell)
        for group in [markerStyle, textStyleMenu, arrowStyle, arrowPath, pencilMode, mosaicMode, widthOption, opacityOption].compactMap({ $0 }) { options.addArrangedSubview(group) }
        shapeMode.segmentCount = 3; shapeMode.trackingMode = .selectOne
        lineStyle.segmentCount = 2; lineStyle.trackingMode = .selectOne
        lineStyle.setImage(ScreenshotToolbarSymbols.line(dashed: false), forSegment: 0)
        lineStyle.setImage(ScreenshotToolbarSymbols.line(dashed: true), forSegment: 1)
        shapeMode.target = self; shapeMode.action = #selector(changeShapeMode(_:))
        shapeMode.setAccessibilityLabel(L10n.text("shapeMode"))
        for mode in ScreenshotShapeMode.allCases {
            shapeMode.setImage(ScreenshotToolbarSymbols.shape(mode), forSegment: mode.rawValue)
            shapeMode.setToolTip(mode.title, forSegment: mode.rawValue)
            shapeMode.setWidth(Design.ScreenshotEditor.toolbarOptionSegmentWidth, forSegment: mode.rawValue)
        }
        for index in 0..<2 {
            lineStyle.setToolTip(index == 0 ? L10n.text("solid") : L10n.text("dashed"), forSegment: index)
            lineStyle.setWidth(Design.ScreenshotEditor.toolbarOptionSegmentWidth, forSegment: index)
        }
        lineStyle.target = self; lineStyle.action = #selector(changeLineStyle(_:))
        lineStyle.setAccessibilityLabel(L10n.text("lineStyle"))
        cornerControl.target = self; cornerControl.action = #selector(changeCorner(_:))
        cornerControl.setAccessibilityLabel(L10n.text("cornerRadius"))
        cornerControl.widthAnchor.constraint(equalToConstant: Design.ScreenshotEditor.toolbarSliderWidth).isActive = true
        cornerOption = cornerControl
        options.insertArrangedSubview(shapeMode, at: 1)
        options.insertArrangedSubview(lineStyle, at: 2)
        options.insertArrangedSubview(focusShape, at: 1)
        if let cornerOption { options.addArrangedSubview(cornerOption) }
        toolbarUI.addDivider()
        for (button, action) in [(undoButton, #selector(undo)), (redoButton, #selector(redo))] {
            button.target = self; button.action = action; toolbar.addArrangedSubview(button)
        }
        actionButtons[.undo]=undoButton; actionButtons[.redo]=redoButton
        toolbarUI.addDivider()
        for (symbol, title, action) in [("text.viewfinder", L10n.text("recognizeText"), #selector(ocrImage)), ("rectangle.arrowtriangle.2.outward", L10n.text("scrollingScreenshot"), #selector(scrollImage)), ("square.and.arrow.down", L10n.text("saveScreenshot"), #selector(saveImage)), ("square.and.arrow.up", L10n.text("share"), #selector(shareImage(_:))), ("pin", L10n.text("pinImage"), #selector(pinImage)), ("xmark", L10n.text("cancelScreenshot"), #selector(cancelEditing)), ("checkmark", L10n.text("copy"), #selector(copyImage))] {
            let button = action == #selector(scrollImage) ? scrollButton : ScreenshotToolbarButton(symbol: symbol, title: title, target: self, action: action)
            button.target = self; button.action = action
            toolbar.addArrangedSubview(button)
            let kind:ScreenshotToolbarAction = action == #selector(ocrImage) ? .ocr:action == #selector(scrollImage) ? .scroll:action == #selector(saveImage) ? .save:action == #selector(shareImage(_:)) ? .share:action == #selector(pinImage) ? .pin:action == #selector(cancelEditing) ? .cancel:.copy
            if kind == .copy && isPinEditing { button.action = #selector(updatePin) }
            actionButtons[kind]=button
        }
        dragButton.onDragBegan = { [weak self] in
            guard let self, let panel = self.toolbarPanel else { return }
            self.dismissColorPanel()
            self.toolbarDragStart = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        }
        dragButton.onDrag = { [weak self] delta in self?.dragToolbar(by: delta) }
        dragButton.onDragEnded = { [weak self] in self?.toolbarDragStart = nil }
        toolbar.addArrangedSubview(dragButton); actionButtons[.drag]=dragButton
        colorPanelObservers.append(NotificationCenter.default.addObserver(forName:ScreenshotToolbarPreferences.changed,object:self.toolbarPreferences,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {self?.applyToolbarPreferences()}
        })
        keyboardMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self,let owner=event.window,owner === self.window || owner === self.toolbarPanel,
                      !(owner.firstResponder is NSTextView),!(owner.firstResponder is NSTextField) else{return false}
                return self.performShortcut(event)
            }
            return consumed ? nil:event
        }
        canvas.onChange={ [weak self] in self?.updateControls() }
        canvas.onInteraction = { [weak self] in self?.dismissColorPanel() }
        selectionOverlay?.onInteraction = { [weak self] in self?.dismissColorPanel() }
        canvas.onCancel = { [weak self] in self?.close() }
        canvas.onEmptyDoubleClick={ [weak self] in
            guard let self,!self.isPinEditing else{return false}
            switch self.capturePreferences.doubleClick {
            case .copy:self.copyImage()
            case .save:self.saveImage()
            case .pin:self.pinImage()
            case .none:return false
            }
            return true
        }
        selectionOverlay?.onSelectionChanged = { [weak self] in self?.refreshSelectionSize(); self?.positionToolbar() }
        sizeToolbar.onWidthChange = { [weak self] value in self?.selectionOverlay?.setPixelSize(width: value); self?.refreshSelectionSize(); self?.positionToolbar() }
        sizeToolbar.onHeightChange = { [weak self] value in self?.selectionOverlay?.setPixelSize(height: value); self?.refreshSelectionSize(); self?.positionToolbar() }
        sizeToolbar.onRatioChange = { [weak self] ratio in self?.selectionOverlay?.setAspectRatio(ratio); self?.refreshSelectionSize(); self?.positionToolbar() }
        sizeToolbar.onCornerChange = { [weak self] radius in
            guard let self else { return }
            self.preferences.outputCornerRadius = radius
            self.canvas.outputCornerRadius = radius
            self.selectionOverlay?.refreshCornerAppearance()
            self.refreshSelectionSize()
        }
        refreshSelectionSize()
        updateControls()
        view.layoutSubtreeIfNeeded()
        tools.setContentSize(view.fittingSize)
        positionToolbar()
        window.makeFirstResponder(canvas)
    }
    required init?(coder:NSCoder){nil}
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        toolbarPanel?.orderFrontRegardless()
        sizePanel?.orderFrontRegardless()
        sizePanel?.makeFirstResponder(nil)
        window?.makeKey()
        window?.makeFirstResponder(canvas)
    }
    override func close() {
        finishEditingWindows()
        super.close()
    }
    func windowWillClose(_ notification: Notification) { finishEditingWindows() }
    private func finishEditingWindows() {
        guard !editingFinished else{return};editingFinished=true
        canvas.endParameterChange(); canvas.commitText()
        canvas.cancelHighlighterRecognition()
        if let keyboardMonitor {NSEvent.removeMonitor(keyboardMonitor);self.keyboardMonitor=nil}
        let ended=onEditingEnded; onEditingEnded=nil
        ended?()
        colorPanelObservers.forEach(NotificationCenter.default.removeObserver)
        colorPanelObservers.removeAll()
        colorWell.dismissSelection()
        if let toolbarPanel {
            window?.removeChildWindow(toolbarPanel)
            toolbarPanel.close()
            self.toolbarPanel = nil
        }
        if let sizePanel {
            window?.removeChildWindow(sizePanel); sizePanel.close(); self.sizePanel = nil
        }

    }
    private func fitToolbar() {
        guard let toolbarPanel, let content = toolbarPanel.contentView,
              let stack = content.subviews.first as? NSStackView else { return }
        toolbarUI.fitVisibleContent()
        content.layoutSubtreeIfNeeded()
        toolbarPanel.setContentSize(stack.fittingSize)
        content.layoutSubtreeIfNeeded()
        positionToolbar()
    }
    private func dragToolbar(by delta: CGSize) {
        guard let start = toolbarDragStart else { return }
        manualToolbarTopLeft = CGPoint(x: start.x + delta.width, y: start.y + delta.height)
        positionToolbar()
    }
    private func refreshSelectionSize() {
        guard let selectionOverlay else { return }
        sizeToolbar.update(size: selectionOverlay.pixelSize, ratio: selectionOverlay.aspectRatio, cornerRadius: canvas.outputCornerRadius)
    }
    private func positionSizeToolbar() {
        guard let overlay = selectionOverlay, let sizePanel, let window else { return }
        let size = sizeToolbar.fittingSize
        let width = size.width
        if sizePanel.frame.size != size { sizePanel.setContentSize(size) }
        sizeToolbar.layoutSubtreeIfNeeded()
        let margin = Design.Space.s
        let x = min(max(overlay.selection.minX, margin), max(margin, overlay.bounds.width - width - margin))
        let above = overlay.selection.maxY + margin
        let y = above + size.height <= overlay.bounds.height - margin ? above : overlay.selection.maxY - size.height - margin
        let origin = CGPoint(x: window.frame.minX + x, y: window.frame.minY + min(max(y, margin), overlay.bounds.height - size.height - margin))
        if sizePanel.frame.origin != origin { sizePanel.setFrameOrigin(origin) }
    }
    private func positionToolbar() {
        if let shadow=previewShadow,let parent=canvas.superview {
            shadow.frame=parent.bounds;shadow.image=canvas.image;shadow.imageRect=canvas.frame;shadow.radius=canvas.outputCornerRadii.width;shadow.style=shadowStyle;shadow.needsDisplay=true
        }
        positionSizeToolbar()
        guard let toolbarPanel, let window else { return }
        let selected = selectionOverlay?.selection ?? centeredOverlay?.selection ?? .zero
        let bounds = window.contentView?.bounds ?? .zero
        let height = toolbarPanel.frame.height
        let margin = Design.Space.s
        if let point = manualToolbarTopLeft {
            let x = min(max(point.x, window.frame.minX + margin), max(window.frame.minX + margin, window.frame.maxX - toolbarPanel.frame.width - margin))
            let y = min(max(point.y - height, window.frame.minY + margin), max(window.frame.minY + margin, window.frame.maxY - height - margin))
            toolbarPanel.setFrameOrigin(CGPoint(x: x, y: y))
            manualToolbarTopLeft = CGPoint(x: x, y: y + height)
            return
        }
        let x = min(max(selected.maxX - toolbarPanel.frame.width, margin), max(margin, bounds.width - toolbarPanel.frame.width - margin))
        let below = selected.minY - height - margin
        let y = below >= margin ? below : min(selected.maxY + margin, bounds.height - height - margin)
        toolbarPanel.setFrameOrigin(CGPoint(x: window.frame.minX + x, y: window.frame.minY + max(margin, y)))
    }
    private func didExport(_ image:NSImage? = nil) {
        guard !editingFinished else{return}
        if isPinEditing { onPinUpdate?(image ?? output(),canvas.document) }
        if !isPinEditing,!playedCompletionSound,capturePreferences.completionSound {playedCompletionSound=true;soundPlayer()}
        onExportSuccess?(); close()
    }
    @objc private func updatePin() { didExport() }
    private func applyToolbarPreferences() { updateControls() }
    @discardableResult func performShortcut(_ event:NSEvent)->Bool {
        guard !editingFinished else{return false}
        if [UInt16(51),117].contains(event.keyCode),event.modifierFlags.intersection([.command,.option,.control]).isEmpty {
            return canvas.deleteSelected()
        }
        if event.modifierFlags.contains(.command),event.modifierFlags.intersection([.option,.control]).isEmpty {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z":if event.modifierFlags.contains(.shift) {redo()}else{undo()};return true
            case "c":if !event.isARepeat {copyImage()};return true
            case "s":if !event.isARepeat {saveImage()};return true
            default:break
            }
        }
        guard let action=toolbarPreferences.action(for:event,context:isPinEditing ? .pinEdit:.screenshotEdit) else{return false}
        if action == .scroll && onScroll == nil || action == .pin && isPinEditing {return false}
        guard actionButtons[action] != nil || (isPinEditing && action == .copy) else{return false}
        if event.isARepeat {return true}
        if let tool=action.tool,let button=toolButtons.first(where:{$0.tag==tool.rawValue}) {selectTool(button);return true}
        switch action {
        case .undo:if canvas.document.canUndo {undo()}
        case .redo:if canvas.document.canRedo {redo()}
        case .ocr:ocrImage()
        case .scroll:scrollImage()
        case .save:saveImage()
        case .pin:pinImage()
        case .copy:if isPinEditing {updatePin()}else{copyImage()}
        case .share:if let button=actionButtons[.share] {shareImage(button)}
        case .cancel:cancelEditing()
        default:return false
        }
        return true
    }
    @objc private func cancelEditing() { close() }
    func refreshInterfaceLanguage() {
        window?.title = L10n.text("screenshotEditor")
        toolbarPanel?.title = L10n.text("screenshotToolbar")
        sizePanel?.title = L10n.text("screenshotDimensions")
        selectionOverlay?.setAccessibilityLabel(L10n.text("screenshotSelectionDragTheBorderOrAny"))
        sizeToolbar.refreshInterfaceLanguage()
        dragButton.updateLocalizedLabel(L10n.text("dragToolbar"))
        colorWell.setAccessibilityLabel(L10n.text("annotationColor"))
        colorWell.toolTip = L10n.text("annotationColor")
        let labeledControls: [(NSControl, String)] = [
            (markerStyle, "marker"), (textStyleMenu, "textStyle"), (focusShape, "spotlightShape"),
            (arrowStyle, "arrowStyle"), (arrowPath, "arrowPath"), (pencilMode, "penMode"),
            (opacityControl, "annotationOpacity"), (mosaicMode, "redactionMode"),
            (shapeMode, "shapeMode"), (lineStyle, "lineStyle"), (cornerControl, "cornerRadius")
        ]
        for (control, key) in labeledControls {
            control.setAccessibilityLabel(L10n.text(key))
        }
        opacityControl.toolTip = opacityControl.formatValue(opacityControl.doubleValue)
        let segmentTitles: [(NSSegmentedControl, [String])] = [
            (markerStyle, ScreenshotAnnotationMarker.allCases.map(\.title)),
            (textStyleMenu, ScreenshotEditorTextStyle.toolbarCases.map(\.title)),
            (focusShape, [L10n.text("rectangularSpotlight"), L10n.text("ellipticalSpotlight")]),
            (arrowStyle, ScreenshotArrowStyle.allCases.map(\.title)),
            (arrowPath, [L10n.text("straightLine"), L10n.text("curvedLine")]),
            (pencilMode, ScreenshotPencilMode.toolbarCases.map(\.title)),
            (mosaicMode, [L10n.text("pixelate"), L10n.text("gaussianBlur")]),
            (shapeMode, ScreenshotShapeMode.allCases.map(\.title)),
            (lineStyle, [L10n.text("solid"), L10n.text("dashed")])
        ]
        for (control, titles) in segmentTitles {
            for (index, title) in titles.enumerated() {
                control.setToolTip(title, forSegment: index)
                control.image(forSegment: index)?.accessibilityDescription = title
            }
        }
        for button in toolButtons {
            if let tool = ScreenshotEditorTool(rawValue: button.tag) {
                button.updateLocalizedLabel(tool.title)
            }
        }
        updateControls()
    }

    private func updateControls() {
        synchronizingToolControls = true
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit(); NSAnimationContext.endGrouping()
            synchronizingToolControls = false
        }
        for (action,button) in actionButtons {
            button.isHidden = !toolbarPreferences.item(action).visible || (isPinEditing && (action == .pin || action == .scroll))
            let title: String
            if action == .copy && isPinEditing { title = L10n.text("capture.applyChanges") }
            else if action == .cancel { title = L10n.text("cancelScreenshot") }
            else { title = action.title }
            let hint = toolbarPreferences.hint(action)
            if button.title != title {
                let imagePosition = button.imagePosition
                button.title = title
                button.imagePosition = imagePosition
            }
            button.updateLocalizedLabel(title, toolTip: hint.isEmpty ? title : L10n.format("shortcutHint", title, hint))
        }
        undoButton.isEnabled = canvas.document.canUndo; redoButton.isEnabled = canvas.document.canRedo
        toolButtons.forEach {
            let selected = $0.tag == canvas.tool?.rawValue
            $0.state = selected ? .on : .off
            $0.needsDisplay = true
        }
        scrollButton.isEnabled = onScroll != nil
        toolbarUI.hasOptions = canvas.tool != nil
        guard let tool = canvas.tool else { fitToolbar(); return }
        widthControl.minValue = Double(tool.sizeRange.lowerBound)
        widthControl.maxValue = Double(tool.sizeRange.upperBound)
        widthControl.doubleValue = Double(canvas.width)
        widthControl.setAccessibilityLabel(canvas.tool == .mosaic ? L10n.text("intensity") : canvas.tool == .text ? L10n.text("fontSize") : L10n.text("annotationThickness"))
        widthControl.isEnabled = canvas.tool != .highlight
        opacityControl.isEnabled = canvas.tool != .mosaic
        let text = canvas.tool == .text
        let mosaic = canvas.tool == .mosaic
        let focus = canvas.tool == .highlight
        if mosaic { widthControl.formatValue = { L10n.format("intensity2", String(describing: Int($0.rounded()))) } }
        else if text { widthControl.formatValue = { L10n.format("fontSizePt", String(describing: Int($0.rounded()))) } }
        else { widthControl.formatValue = { L10n.format("widthPx", String(describing: Int($0.rounded()))) } }
        widthControl.toolTip = widthControl.formatValue(Double(canvas.width))
        colorWell.isHidden = mosaic || focus
        focusShape.isHidden = !focus
        focusShape.setSelectedSegment(canvas.focusIsEllipse ? 1 : 0, animated: false)
        markerStyle.isHidden = !text
        markerStyle.setSelectedSegment(canvas.marker.rawValue, animated: false)
        textStyleOption?.isHidden = !text
        let shape = canvas.tool == .rectangle || canvas.tool == .ellipse
        let mode: ScreenshotShapeMode = canvas.filled ? (canvas.fillHasBorder ? .fill : .solid) : .outline
        shapeMode.isHidden = !shape
        shapeMode.setSelectedSegment(mode.rawValue, animated: false)
        for shapeModeValue in ScreenshotShapeMode.allCases {
            shapeMode.setImage(ScreenshotToolbarSymbols.shape(shapeModeValue, ellipse: canvas.tool == .ellipse), forSegment: shapeModeValue.rawValue)
        }
        lineStyle.isHidden = !(shape && mode != .solid || canvas.tool == .line)
        lineStyle.setSelectedSegment(canvas.dashed ? 1 : 0, animated: false)
        widthOption?.isHidden = canvas.tool == .highlight || (shape && mode == .solid)
        opacityOption?.isHidden = text || mosaic || canvas.tool == .line || canvas.tool == .arrow || (shape && mode != .fill)
        arrowStyle.isHidden = canvas.tool != .arrow; arrowStyle.setSelectedSegment(ScreenshotArrowStyle.allCases.firstIndex(of: canvas.arrowStyle) ?? 1, animated: false)
        pencilMode.isHidden = canvas.tool != .pencil
        pencilMode.setSelectedSegment(ScreenshotPencilMode.toolbarCases.firstIndex(of: canvas.pencilMode) ?? 1, animated: false)
        cornerOption?.isHidden = canvas.tool != .rectangle && !(focus && !canvas.focusIsEllipse)
        cornerControl.doubleValue = focus || canvas.rounded ? Double(canvas.cornerRadius) : 0
        cornerControl.toolTip = L10n.format("cornerRadiusPt", String(describing: Int(cornerControl.doubleValue)))
        mosaicMode.isHidden = !mosaic
        arrowPath.isHidden = canvas.tool != .arrow
        mosaicMode.setSelectedSegment(canvas.blurred ? 1 : 0, animated: false)
        arrowPath.setSelectedSegment(canvas.curved ? 1 : 0, animated: false)
        colorWell.color = canvas.color
        textStyleMenu.setSelectedSegment(ScreenshotEditorTextStyle.toolbarCases.firstIndex(of: canvas.textStyle) ?? 0, animated: false)
        opacityControl.doubleValue = Double(canvas.tool == .highlight ? canvas.highlightOpacity : canvas.opacity)
        opacityControl.toolTip = opacityControl.formatValue(opacityControl.doubleValue)
        fitToolbar()
    }
    @objc private func selectTool(_ sender: NSButton) {
        dismissColorPanel()
        guard let chosen = ScreenshotEditorTool(rawValue: sender.tag) else { return }
        canvas.commitText()
        canvas.tool = canvas.tool == chosen ? nil : chosen
        if let current = canvas.tool { preferences.options(for: current).apply(to: canvas, tool: current) }
        canvas.selected = nil; canvas.needsDisplay = true; updateControls()
    }
    private func saveToolOptions() {
        guard let tool = canvas.tool else { return }
        preferences.save(ScreenshotToolOptions(canvas: canvas, tool: tool), for: tool)
    }
    private func dismissColorPanel() {
        canvas.endParameterChange();colorWell.dismissSelection()
    }
    private func finishPaletteBeforeChanging(_ sender: NSSegmentedControl) -> Int {
        // Preserve the current click first; syncing controls when finalizing the prior swatch action must not overwrite the newly chosen value.
        let choice = sender.selectedSegment
        dismissColorPanel()
        if let control = sender as? SlidingSegmentedControl { control.setSelectedSegment(choice, animated: false) }
        else { sender.selectedSegment = choice }
        return choice
    }
    @objc private func changeWidth(_ sender: NSSlider) {
        canvas.highlighterManualHeight = true
        canvas.width = CGFloat(sender.doubleValue.rounded())
        sender.toolTip = widthControl.formatValue(Double(canvas.width))
        (sender as? ScreenshotValueSlider)?.updateValueCaption()
        canvas.updateSelected { $0.width = canvas.width }
        saveToolOptions()
    }
    @objc private func changeMarker(_ sender: NSSegmentedControl) {
        let choice = finishPaletteBeforeChanging(sender)
        canvas.commitText()
        canvas.marker = ScreenshotAnnotationMarker(rawValue: choice) ?? .none
        canvas.updateSelected {
            $0.marker = canvas.marker
            if $0.marker != .none, $0.markerAnchor == nil {
                let radius = $0.markerSize * ($0.marker == .dot ? Design.ScreenshotEditor.annotationDotRatio : Design.ScreenshotEditor.annotationNumberRatio)
                $0.markerAnchor = ScreenshotEditorGeometry.markerAnchor(frame: $0.textEditorFrame, bounds: canvas.bounds, radius: radius)
            }
            if $0.marker == .number, $0.serial == 0 { $0.serial = canvas.nextAnnotationNumber }
        }
        updateControls()
        saveToolOptions()
    }
    @objc private func changeArrowStyle(_ sender: NSSegmentedControl) {
        let choice = finishPaletteBeforeChanging(sender)
        canvas.arrowStyle = ScreenshotArrowStyle.allCases[choice]
        canvas.updateSelected { $0.arrowStyle = canvas.arrowStyle; $0.opacity = 1 }
        saveToolOptions()
    }
    @objc private func changePencilMode(_ sender: NSSegmentedControl) {
        let choice = finishPaletteBeforeChanging(sender)
        canvas.rememberPencilOpacity()
        canvas.pencilMode = ScreenshotPencilMode.toolbarCases[choice]
        canvas.opacity = canvas.pencilMode == .highlighter ? canvas.pencilHighlighterOpacity : canvas.pencilFreehandOpacity
        canvas.highlighterManualHeight = false
        canvas.updateSelected {
            $0.pencilMode = canvas.pencilMode; $0.opacity = canvas.opacity
            if $0.pencilMode == .highlighter { $0.end.y = $0.start.y }
            else if $0.points.isEmpty { $0.points = [$0.end] }
        }
        saveToolOptions(); updateControls()
    }
    @objc private func changeFocusShape(_ sender: NSSegmentedControl) {
        let choice = finishPaletteBeforeChanging(sender)
        canvas.focusIsEllipse = choice == 1
        canvas.updateSelected { $0.focusIsEllipse = canvas.focusIsEllipse }
        updateControls()
        saveToolOptions()
    }
    @objc private func changeTextStyle(_ sender: NSSegmentedControl) {
        let choice = finishPaletteBeforeChanging(sender)
        canvas.textStyle = ScreenshotEditorTextStyle.toolbarCases[choice]
        canvas.updateSelected { $0.textStyle = canvas.textStyle }
        updateControls()
        saveToolOptions()
    }
    @objc private func changeOpacity(_ sender:NSSlider) {
        canvas.opacity = CGFloat(sender.doubleValue); canvas.highlightOpacity = canvas.opacity
        if canvas.tool == .pencil { canvas.rememberPencilOpacity() }
        if canvas.tool == .rectangle || canvas.tool == .ellipse { canvas.fillOpacity = canvas.opacity }
        sender.toolTip = L10n.format("opacity2", String(describing: Int(sender.doubleValue * 100)))
        (sender as? ScreenshotValueSlider)?.updateValueCaption()
        canvas.updateSelected { $0.opacity = canvas.opacity }
        saveToolOptions()
    }
    @objc private func changeShapeMode(_ sender: NSSegmentedControl) {
        let choice = finishPaletteBeforeChanging(sender)
        let mode = ScreenshotShapeMode(rawValue: choice) ?? .outline
        canvas.filled = mode != .outline; canvas.fillHasBorder = mode == .fill
        canvas.opacity = mode == .fill ? canvas.fillOpacity : 1
        canvas.updateSelected { $0.shapeMode = mode; $0.opacity = canvas.opacity }
        updateControls()
        saveToolOptions()
    }
    @objc private func changeLineStyle(_ sender: NSSegmentedControl) {
        let choice = finishPaletteBeforeChanging(sender)
        canvas.dashed = choice == 1
        canvas.updateSelected { $0.dashed = canvas.dashed }
        saveToolOptions()
    }
    @objc private func changeCorner(_ sender: NSSlider) {
        canvas.cornerRadius = CGFloat(sender.doubleValue); canvas.rounded = sender.doubleValue > 0
        sender.toolTip = L10n.format("cornerRadiusPt", String(describing: Int(sender.doubleValue)))
        (sender as? ScreenshotValueSlider)?.updateValueCaption()
        canvas.updateSelected { $0.rounded = canvas.rounded; $0.cornerRadius = canvas.cornerRadius }
        saveToolOptions()
    }
    @objc private func changeMosaicMode(_ sender: NSSegmentedControl) {
        let choice = finishPaletteBeforeChanging(sender)
        canvas.blurred = choice == 1
        canvas.updateSelected { $0.blurred = canvas.blurred }
        saveToolOptions()
    }
    @objc private func changeArrowPath(_ sender: NSSegmentedControl) {
        let choice = finishPaletteBeforeChanging(sender)
        canvas.curved = choice == 1
        canvas.updateSelected { $0.setCurved(canvas.curved) }
        canvas.needsDisplay = true
        saveToolOptions()
    }
    @objc private func undo(){dismissColorPanel();canvas.undoEdit();saveToolOptions();updateControls()}
    @objc private func redo(){dismissColorPanel();canvas.redoEdit();saveToolOptions();updateControls()}
    private func flatOutput()->NSImage{dismissColorPanel();canvas.commitText();return canvas.renderedImage()}
    private func output()->NSImage{let image=flatOutput();return isPinEditing ? image:ScreenshotShadowRendering.image(image,style:shadowStyle)}
    /// Shares export semantics with the capture bar: finalize stitching first, then invoke the standard screenshot export path.
    func performScrollAction(_ action: ScreenshotScrollAction) {
        switch action {
        case .edit: break
        case .copy: copyImage()
        case .save: saveImage()
        case .ocr: ocrImage()
        case .pin: pinImage()
        }
    }
    @objc private func copyImage(){let image=output();if clipboardWriter(image) {didExport(image)}}
    @objc private func shareImage(_ sender:NSButton) {
        let image=output()
        ScreenshotSharingSession.present(image,from:sender,current:&sharing,additionalWindows:sharingCompanionWindow.map{[$0]} ?? [],serviceChosen:{ [weak self] in
            self?.didExport(image);self?.close()
        })
    }
    @objc private func saveImage() {
        let image=output()
        ScreenshotSaving.save(image,parent:window,preferences:savePreferences) { [weak self] in self?.didExport(image) }
    }
    @objc private func pinImage(){if let onPin {let image=flatOutput();onPin(image);didExport(image)}}
    @objc private func ocrImage(){if let onOCR {let image=flatOutput();onOCR(image);didExport(image)}}
    @objc private func scrollImage(){onScroll?(output())}
}

@MainActor final class ScreenshotEditorCanvas:ThemedDrawingView,NSTextViewDelegate {
    override func applyTheme(_ palette: ThemePalette) {
        super.applyTheme(palette)
        textView?.insertionPointColor = palette.accent
        layersOverlay.needsDisplay = true
        let hasActiveBrush = highlighterCursor.map { NSCursor.current === $0 } ?? false
        highlighterCursor = nil
        if hasActiveBrush && highlighterActive { setHighlighterCursor(height: highlighterCursorHeight) }
    }

    private(set) var image:NSImage
    var outputCornerRadius: CGFloat = 0 { didSet { updateOutputClip(); needsDisplay = true } }
    private let outputClip = CAShapeLayer()
    var outputCornerRadii: CGSize {
        guard outputCornerRadius > 0, let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .zero }
        return ScreenshotSelectionSizing.cornerRadii(outputCornerRadius, logicalSize: image.size,
            pixelSize: CGSize(width: pixels.width, height: pixels.height))
    }
    private func updateOutputClip() {
        let radii = outputCornerRadii
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outputClip.frame = bounds
        outputClip.contentsScale = window?.backingScaleFactor ?? 1
        outputClip.path = CGPath(roundedRect: bounds, cornerWidth: radii.width, cornerHeight: radii.height, transform: nil)
        outputClip.fillColor = Design.ScreenshotEditor.highlightFill.cgColor
        layer?.mask = outputCornerRadius > 0 ? outputClip : nil
        CATransaction.commit()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateOutputClip() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateOutputClip() }
    var document=ScreenshotEditorDocument() { didSet { layersOverlay.needsDisplay = true } }
    private lazy var layersOverlay = ScreenshotEditorLayersOverlay { [weak self] in self?.drawLayersAboveTextEditor() }
    private var effects: ScreenshotEditorEffects
    private var effectOrigin = CGPoint.zero
    private var sharedEffects = false
    var tool: ScreenshotEditorTool? = nil { didSet { prepareHighlighter() } }
    var arrowStyle: ScreenshotArrowStyle = .solid
    var pencilMode: ScreenshotPencilMode = .freehand { didSet { prepareHighlighter() } }
    var highlighterManualHeight = false
    private let lineRecognizer: ScreenshotTextLineRecognizing
    private var lineTask: Task<Void, Never>?
    private var textLines: [CGRect]?
    private var highlighterCursor: NSCursor?
    private var highlighterCursorHeight: CGFloat = 0
    var pencilFreehandOpacity: CGFloat = 1
    var pencilHighlighterOpacity: CGFloat = Design.ScreenshotEditor.highlighterOpacity
    func rememberPencilOpacity() {
        if pencilMode == .highlighter { pencilHighlighterOpacity = opacity }
        else { pencilFreehandOpacity = opacity }
    }
    private var highlighterActive: Bool { tool == .pencil && pencilMode == .highlighter }
    private func prepareHighlighter() {
        guard highlighterActive else { highlighterManualHeight = false; return }
        guard textLines == nil, lineTask == nil, let image = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let recognizer = lineRecognizer
        lineTask = Task { [weak self] in
            let result = (try? await recognizer.lines(in: image)) ?? []
            guard !Task.isCancelled, let self else { return }
            self.textLines = result; self.lineTask = nil
        }
    }
    func cancelHighlighterRecognition() { lineTask?.cancel(); lineTask = nil }
    private func highlighterLine(at point: CGPoint) -> CGRect? {
        highlighterManualHeight ? nil : ScreenshotHighlighter.line(at: point, in: textLines ?? [], size: bounds.size)
    }
    private func setPointer(at point: CGPoint) {
        guard highlighterActive, editCursor(at: point) == .drawing else { editCursor(at: point).cursor.set(); return }
        let height = highlighterLine(at: point).map { $0.height + Design.ScreenshotEditor.highlighterTextPadding * 2 } ?? width
        setHighlighterCursor(height: height)
    }
    private func setHighlighterCursor(height: CGFloat) {
        if highlighterCursor == nil || highlighterCursorHeight != height {
            highlighterCursor = ScreenshotHighlighter.cursor(height: height, palette: theme)
            highlighterCursorHeight = height
        }
        highlighterCursor?.set()
    }
    var color=Design.ScreenshotEditor.defaultStrokeColor
    var textStyle: ScreenshotEditorTextStyle = .background
    var width:CGFloat=ScreenshotEditorTool.rectangle.defaultSize
    var opacity:CGFloat=1
    var fillOpacity = Design.ScreenshotEditor.defaultFillOpacity
    var highlightOpacity = Design.ScreenshotEditor.defaultFocusOpacity
    var filled=false,rounded=false,blurred=false,curved=false
    var fillHasBorder = false
    var dashed = false
    var cornerRadius = Design.ScreenshotEditor.defaultCornerRadius
    var marker: ScreenshotAnnotationMarker = .none
    var focusIsEllipse = false
    var nextAnnotationNumber: Int { (document.visible.filter { $0.tool == .text && $0.marker == .number }.map(\.serial).max() ?? 0) + 1 }
    var selected:UUID? { didSet { synchronizeTextChrome() } }
    var onChange:(()->Void)?
    var onCancel:(()->Void)?
    var onEmptyDoubleClick:(()->Bool)?
    var onInteraction: (() -> Void)?
    private var anchor=CGPoint.zero
    private var baseline:ScreenshotEditorStroke?
    private var resizeHandle: Int?
    private var dragged=false
    private var emptyClickDown: (point: CGPoint, timestamp: TimeInterval)?
    private var lastEmptyClick: (point: CGPoint, timestamp: TimeInterval)?
    private var samples=0
    private var textView:NSTextView?
    private var textStroke:ScreenshotEditorStroke?
    private(set) var placingAnnotation = false
    private let textChrome = ScreenshotTextEditorChrome()
    private var pointerTracking: NSTrackingArea?
    private var textResizeBaseline: ScreenshotEditorStroke?
    private var resizingTextLeft = false
    private var resizingWhileEditing = false
    var onRegionDragBegan: ((NSEvent) -> Void)?
    var onRegionDragged: ((NSEvent) -> Void)?
    var onRegionDragEnded: ((NSEvent) -> Void)?
    private var draggingRegion = false
    init(image:NSImage, lineRecognizer: ScreenshotTextLineRecognizing = ScreenshotTextLineRecognizer()) {
        self.lineRecognizer = lineRecognizer
        self.image=image; self.effects=ScreenshotEditorEffects(base:image)
        super.init(frame:NSRect(origin:.zero,size:image.size))
        wantsLayer = true
        layersOverlay.frame = bounds
        layersOverlay.autoresizingMask = [.width, .height]
        addSubview(layersOverlay)
        textChrome.onResizeBegan = { [weak self] left in
            guard let self, !self.placingAnnotation else { return }
            self.onInteraction?()
            self.resizingWhileEditing = self.textView != nil
            if let editor = self.textView {
                self.beginParameterChange()
                editor.unmarkText()
                self.textDidChange(Notification(name: NSText.didChangeNotification))
                self.textResizeBaseline = self.textStroke
            } else {
                self.commitText()
                self.textResizeBaseline = self.document.visible.first { $0.id == self.selected && $0.tool == .text }
            }
            self.resizingTextLeft = left
        }
        textChrome.onResize = { [weak self] delta in self?.resizeText(by: delta) }
        textChrome.onMoveBegan = { [weak self] in
            guard let self, !self.placingAnnotation else { return }
            self.onInteraction?(); self.commitText(); self.resizingWhileEditing = false
            self.textResizeBaseline = self.document.visible.first { $0.id == self.selected && $0.tool == .text }
        }
        textChrome.onMove = { [weak self] delta in
            guard let self, var stroke = self.textResizeBaseline else { return }
            stroke.translateText(to: CGPoint(x: stroke.start.x+delta.x, y: stroke.start.y+delta.y))
            self.document.preview = stroke; self.synchronizeTextChrome(); self.needsDisplay = true
        }
        textChrome.onResizeEnded = { [weak self] in
            guard let self, self.textResizeBaseline != nil else { return }
            if self.resizingWhileEditing { self.endParameterChange(); self.window?.makeFirstResponder(self.textView) }
            else if let stroke = self.document.preview { self.document.commit(stroke) }
            self.resizingWhileEditing = false
            self.textResizeBaseline = nil; self.synchronizeTextChrome(); self.onChange?()
        }
        textChrome.onMoveEnded = textChrome.onResizeEnded
    }
    required init?(coder:NSCoder){nil}
    func useFrozenEffects(_ image: NSImage, origin: CGPoint) {
        effects = ScreenshotEditorEffects(base: image)
        effectOrigin = origin
        sharedEffects = true
    }
    func renderedImage() -> NSImage {
        ScreenshotEditorRenderer.image(base: image, strokes: document.visible, effects: effects, effectOrigin: effectOrigin, cornerRadiusPixels: outputCornerRadius)
    }
    func replaceImage(_ image: NSImage, rebasing delta: CGPoint) {
        commitText()
        cancelHighlighterRecognition(); textLines = nil
        self.image = image
        prepareHighlighter()
        if sharedEffects {
            effectOrigin.x -= delta.x; effectOrigin.y -= delta.y
        } else { effects = ScreenshotEditorEffects(base: image) }
        document.rebase(by: delta)
        frame.size = image.size
        updateOutputClip()
        needsDisplay = true
    }
    @discardableResult func deleteSelected()->Bool {
        guard textView == nil,!placingAnnotation,let selected else{return false}
        endParameterChange();document.delete(selected)
        self.selected=nil;baseline=nil;resizeHandle=nil
        needsDisplay=true;onChange?();return true
    }
    override func keyDown(with event: NSEvent) {
        if [UInt16(51),117].contains(event.keyCode),event.modifierFlags.intersection([.command,.option,.control]).isEmpty,deleteSelected() {return}
        if event.keyCode == 53, placingAnnotation { commitText() }
        else if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if outputCornerRadius > 0, outputClip.path?.contains(local) == false { return nil }
        return super.hitTest(point)
    }
    override var acceptsFirstResponder:Bool{true}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect:NSRect){
        let radii = outputCornerRadii
        if radii.width > 0 { NSBezierPath(roundedRect: bounds, xRadius: radii.width, yRadius: radii.height).addClip() }
        image.draw(at:.zero,from:.zero,operation:.sourceOver,fraction:1)
        let strokes = document.visible
        let editingIndex = textStroke.flatMap { text in strokes.firstIndex { $0.id == text.id } }
        let content = editingIndex.map { Array(strokes.prefix($0 + 1)) } ?? strokes
        for stroke in content { ScreenshotEditorRenderer.draw(stroke, base: image, effects: effects, effectOrigin: effectOrigin) }
        if let textStroke { ScreenshotEditorTextRendering.drawBackdrop(textStroke) }
        else if placingAnnotation, let preview = document.preview { ScreenshotEditorTextRendering.drawBackdrop(preview) }
        if let selected,let stroke=document.visible.first(where:{$0.id==selected}), stroke.tool != .text {
            if stroke.tool != .line && stroke.tool != .arrow && stroke.tool != .pencil {
                theme.accent.setStroke();let outline=NSBezierPath(rect:stroke.rect);outline.lineWidth=1;outline.stroke()
            }
            for p in handles(stroke){theme.accent.setFill();NSRect(x:p.x-Design.ScreenshotEditor.handleSize/2,y:p.y-Design.ScreenshotEditor.handleSize/2,width:Design.ScreenshotEditor.handleSize,height:Design.ScreenshotEditor.handleSize).fill()}
        }
    }
    private func drawLayersAboveTextEditor() {
        guard let textStroke else { return }
        let strokes = document.visible
        guard let index = strokes.firstIndex(where: { $0.id == textStroke.id }) else { return }
        for stroke in strokes.dropFirst(index + 1) { ScreenshotEditorRenderer.draw(stroke, base: image, effects: effects, effectOrigin: effectOrigin) }
    }
    override func mouseDown(with event:NSEvent){
        onInteraction?()
        let point = convert(event.locationInWindow, from: nil)
        let previousClick = lastEmptyClick
        lastEmptyClick = nil; emptyClickDown = nil
        if bounds.contains(point), textView == nil, !placingAnnotation, tool != .text,
           !document.visible.contains(where: { ScreenshotEditorGeometry.hit(point, stroke: $0) || (($0.tool == .rectangle || $0.tool == .ellipse) && ScreenshotEditorGeometry.path($0).contains(point)) }) {
            // System clickCount may carry over from the selection overlay; accept only a first click that completed inside the canvas.
            if event.clickCount == 2, let previousClick,
               (0...NSEvent.doubleClickInterval).contains(event.timestamp - previousClick.timestamp),
               hypot(point.x - previousClick.point.x, point.y - previousClick.point.y) <= 4,
               onEmptyDoubleClick?() == true { return }
            emptyClickDown = (point, event.timestamp)
        }
        if placingAnnotation, var stroke = document.preview {
            placingAnnotation = false
            stroke.translateText(to: point)
            beginTextEditing(stroke)
            return
        }
        if textView != nil {
            baseline = nil; resizeHandle = nil; dragged = false
            commitText(); selected = nil; window?.makeFirstResponder(self)
            return
        }
        commitText();window?.makeFirstResponder(self);anchor=point;dragged=false;samples=0
        if event.clickCount == 2, let stroke = document.visible.reversed().first(where: { $0.tool == .text && ($0.textEditorFrame.contains(anchor) || $0.hitsMarker(anchor)) }) {
            selected = stroke.id; beginTextEditing(stroke); return
        }
        if let selected,let stroke=document.visible.first(where:{$0.id==selected}),stroke.tool != .text,let handle=handles(stroke).firstIndex(where:{hypot(anchor.x-$0.x,anchor.y-$0.y)<=Design.ScreenshotEditor.handleSize}) {baseline=stroke;resizeHandle=handle;return}
        if let stroke = document.visible.reversed().first(where: { $0.tool == .text && $0.rect.contains(anchor) && !$0.hitsMarker(anchor) }) {
            selected = stroke.id; baseline = nil; resizeHandle = nil
            tool = .text; width = stroke.width; color = stroke.color
            marker = stroke.marker; textStyle = stroke.textStyle; opacity = stroke.opacity
            needsDisplay = true; onChange?(); return
        }
        if let stroke = document.visible.reversed().first(where: { ScreenshotEditorGeometry.hit(anchor, stroke: $0) || (($0.tool == .rectangle || $0.tool == .ellipse) && ScreenshotEditorGeometry.path($0).contains(anchor)) }) {
            selected = stroke.id; baseline = stroke; resizeHandle = stroke.tool == .text && stroke.hitsMarker(anchor) ? 0 : nil
            adoptOptions(from: stroke)
            if stroke.tool == .text, event.clickCount == 2 { beginTextEditing(stroke) }
            needsDisplay = true; onChange?(); return
        }
        let deselectingText=selected.flatMap{id in document.visible.first{$0.id==id}}?.tool == .text
        selected=nil;baseline=nil;resizeHandle=nil
        if deselectingText {needsDisplay=true;onChange?();return}
        guard let tool else {
            if let onRegionDragBegan { draggingRegion = true; NSCursor.closedHand.set(); onRegionDragBegan(event) }
            needsDisplay = true; onChange?(); return
        }
        var stroke=ScreenshotEditorStroke(id:UUID(),tool:tool,start:anchor,end:anchor,color:color,width:width,opacity:tool == .highlight ? highlightOpacity : opacity,filled:filled,rounded:rounded,blurred:blurred,curved:curved)
        stroke.arrowStyle = arrowStyle; stroke.pencilMode = pencilMode
        if tool == .line || tool == .arrow { stroke.opacity = 1 }
        if highlighterActive, let line = highlighterLine(at: anchor) {
            stroke.start.y = line.midY; stroke.end.y = line.midY
            stroke.width = line.height + Design.ScreenshotEditor.highlighterTextPadding * 2
        }
        stroke.fillHasBorder = fillHasBorder; stroke.dashed = dashed; stroke.cornerRadius = cornerRadius
        stroke.focusIsEllipse = focusIsEllipse
        if tool == .text {
            stroke.textStyle = textStyle; stroke.marker = marker; stroke.textLayoutBounds = bounds
            stroke.textMaximumWidth = min(Design.AnnotationEditor.maximumAutoWidth, bounds.width - stroke.start.x - Design.AnnotationEditor.inset)
            stroke.layoutText("")
            if marker != .none {
                stroke.markerAnchor = anchor
                stroke.serial = marker == .number ? nextAnnotationNumber : 0
                placingAnnotation = true; stroke.isPlacementPreview = true
                stroke.start = CGPoint(x: anchor.x + Design.ScreenshotEditor.annotationTextGap, y: anchor.y)
                stroke.textTopY = nil; stroke.layoutText("")
                document.preview = stroke
                updateTextChrome(for: stroke)
                needsDisplay = true
            } else { beginTextEditing(stroke) }
            return
        }
        document.preview=stroke;needsDisplay=true
    }
    override func mouseDragged(with event:NSEvent){
        emptyClickDown = nil; lastEmptyClick = nil
        if draggingRegion { NSCursor.closedHand.set(); onRegionDragged?(event); return }
        onInteraction?()
        if placingAnnotation { updateAnnotationPreview(at: convert(event.locationInWindow, from: nil)); return }
        let p=convert(event.locationInWindow,from:nil);dragged=true;samples+=1
        if !bounds.contains(p) { NSCursor.arrow.set() }
        else if let baseline { (resizeHandle == nil || baseline.tool == .text ? ScreenshotEditCursor.dragging : editCursor(at: anchor)).cursor.set() }
        else if highlighterActive { setHighlighterCursor(height: document.preview?.width ?? width) }
        if var stroke=baseline {
            if let handle=resizeHandle {
                if stroke.tool == .text, stroke.markerAnchor != nil {
                    if handle == 0 { stroke.markerAnchor = p }
                    else { stroke.translateText(to: p) }
                } else if stroke.tool == .line || stroke.tool == .arrow {
                    switch handle {case 0:stroke.start=p;case 1:stroke.end=p;case 2:stroke.control1=p;default:stroke.control2=p}
                } else if stroke.tool == .pencil {
                    if handle == 0 { stroke.start = p; if stroke.pencilMode == .highlighter { stroke.end.y = p.y } }
                    else {
                        stroke.end = p
                        if stroke.pencilMode == .highlighter { stroke.end.y = stroke.start.y }
                        else if !stroke.points.isEmpty { stroke.points[stroke.points.count - 1] = p }
                    }
                } else {
                    let rect=stroke.rect
                    var x1=rect.minX,y1=rect.minY,x2=rect.maxX,y2=rect.maxY
                    if [0,6,7].contains(handle){x1=p.x};if [2,3,4].contains(handle){x2=p.x}
                    if [0,1,2].contains(handle){y1=p.y};if [4,5,6].contains(handle){y2=p.y}
                    stroke.start=CGPoint(x:x1,y:y1);stroke.end=CGPoint(x:x2,y:y2)
                }
            } else if stroke.tool == .text {
                stroke.translateText(to: CGPoint(x: stroke.start.x + p.x - anchor.x, y: stroke.start.y + p.y - anchor.y))
            } else {stroke.translate(CGPoint(x:p.x-anchor.x,y:p.y-anchor.y))}
            document.preview=stroke
        } else if var stroke=document.preview {
            stroke.end = p
            if stroke.tool == .pencil {
                if stroke.pencilMode == .highlighter { stroke.end.y = stroke.start.y }
                else { stroke.points.append(p) }
            }
            if stroke.tool == .arrow, stroke.curved { stroke.resetCurveControls() }
            document.preview=stroke
        }
        synchronizeTextChrome(); needsDisplay=true
    }
    override func mouseUp(with event:NSEvent){
        if let click = emptyClickDown, bounds.contains(convert(event.locationInWindow, from: nil)) {
            lastEmptyClick = click
        }
        emptyClickDown = nil
        if draggingRegion { draggingRegion = false; onRegionDragEnded?(event); editCursor(at: convert(event.locationInWindow, from: nil)).cursor.set(); return }
        if textView != nil || placingAnnotation { return }
        if let stroke = document.preview, stroke.tool == .text, baseline == nil {
            if dragged { beginTextEditing(stroke) }
            else { document.commit(stroke); selected = stroke.id; onChange?() }
            needsDisplay = true; return
        }
        if let stroke = document.preview, dragged, (baseline != nil || stroke.tool != .pencil || stroke.pencilMode == .highlighter || samples >= 6) {
            document.commit(stroke)
            selected = stroke.tool == .pencil && baseline == nil ? nil : stroke.id
        } else { document.preview = nil }
        baseline=nil;resizeHandle=nil;synchronizeTextChrome();editCursor(at: convert(event.locationInWindow, from: nil)).cursor.set();needsDisplay=true;onChange?()
    }
    private func handles(_ stroke: ScreenshotEditorStroke)->[CGPoint] {
        if stroke.tool == .line || stroke.tool == .arrow {
            return [stroke.start,stroke.end]+(stroke.curved ? [stroke.control1 ?? stroke.start,stroke.control2 ?? stroke.end] : [])
        }
        if stroke.tool == .text { return stroke.markerAnchor.map { [$0] } ?? [] }
        if stroke.tool == .pencil { return stroke.pencilMode == .highlighter ? [stroke.start, stroke.end] : [] }
        let r=stroke.rect
        return [.init(x:r.minX,y:r.minY),.init(x:r.midX,y:r.minY),.init(x:r.maxX,y:r.minY),.init(x:r.maxX,y:r.midY),.init(x:r.maxX,y:r.maxY),.init(x:r.midX,y:r.maxY),.init(x:r.minX,y:r.maxY),.init(x:r.minX,y:r.midY)]
    }
    /// Edits annotations in a refocusable NSTextView, hiding the committed text while editing.
    private func beginTextEditing(_ original: ScreenshotEditorStroke) {
        var stroke = original
        stroke.isPlacementPreview = false; stroke.isEditingPreview = true; stroke.textLayoutBounds = bounds
        stroke.textMaximumWidth = min(Design.AnnotationEditor.maximumAutoWidth, bounds.width - stroke.start.x - Design.AnnotationEditor.inset)
        stroke.textBoxWidth = stroke.textBoxWidth ?? max(Design.AnnotationEditor.defaultWidth, stroke.rect.width)
        if stroke.textTopY == nil { stroke.textTopY = stroke.start.y + max(Design.AnnotationEditor.minimumHeight, stroke.rect.height) }
        stroke.layoutText(stroke.text)
        // Share TextKit 1 with measurement and export so switching layout engines mid-typing does not break IME composition.
        let editor = ScreenshotAnnotationTextView(usingTextLayoutManager:false)
        editor.frame=stroke.textGlyphFrame
        editor.isRichText = false; editor.drawsBackground = false
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = false
        editor.textContainerInset = .zero; editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false; editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = CGSize(width: stroke.textBoxWidth ?? stroke.rect.width, height: .greatestFiniteMagnitude)
        applyTextAppearance(stroke, to: editor)
        editor.string = stroke.text; editor.delegate = self
        textStroke = stroke; textView = editor
        editor.inputLayoutChanged={ [weak self] in self?.textDidChange(Notification(name:NSText.didChangeNotification)) }
        var hidden = stroke; hidden.text = ""; hidden.isEditingPreview = true; document.preview = hidden
        addSubview(editor)
        addSubview(layersOverlay, positioned: .above, relativeTo: editor)
        updateTextChrome(for: stroke)
        window?.makeFirstResponder(editor)
        if !stroke.text.isEmpty { editor.selectAll(nil) }
        textDidChange(Notification(name: NSText.didChangeNotification))
    }
    private func applyTextAppearance(_ stroke: ScreenshotEditorStroke, to editor: NSTextView) {
        let attributes = ScreenshotEditorTextRendering.attributes(for: stroke)
        let foreground = stroke.textStyle == .background ? ScreenshotAnnotationRendering.contrast(for: stroke.color) : stroke.color
        editor.font = Design.ScreenshotEditor.font(size: stroke.width)
        editor.textColor = foreground; editor.insertionPointColor = theme.accent
        editor.drawsBackground = false; editor.alignment = .left
        editor.typingAttributes = attributes
        if !editor.hasMarkedText(), let storage = editor.textStorage, storage.length > 0 { storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length)) }
    }
    private func adoptOptions(from stroke: ScreenshotEditorStroke) {
        tool = stroke.tool; width = stroke.width; color = stroke.color
        filled = stroke.filled; rounded = stroke.rounded; blurred = stroke.blurred; curved = stroke.curved
        if stroke.tool == .highlight { highlightOpacity = stroke.opacity }
        opacity = stroke.opacity; fillHasBorder = stroke.fillHasBorder; dashed = stroke.dashed; cornerRadius = stroke.cornerRadius
        if stroke.shapeMode == .fill { fillOpacity = stroke.opacity }
        arrowStyle = stroke.arrowStyle; pencilMode = stroke.pencilMode
        marker = stroke.marker; focusIsEllipse = stroke.focusIsEllipse
        textStyle = stroke.textStyle
    }
    private func restoreSelectedOptions() {
        if let stroke = document.visible.first(where: { $0.id == selected }) { adoptOptions(from: stroke) }
        else { selected = nil }
        synchronizeTextChrome(); needsDisplay = true; onChange?()
    }
    private func endAnnotationDrag() {
        baseline = nil
        resizeHandle = nil
        dragged = false
        samples = 0
        emptyClickDown = nil
    }

    func undoEdit() {
        endParameterChange()
        commitText()
        endAnnotationDrag()
        document.undo()
        restoreSelectedOptions()
    }

    func redoEdit() {
        endParameterChange()
        commitText()
        endAnnotationDrag()
        document.redo()
        restoreSelectedOptions()
    }
    private func currentTextVersion() -> ScreenshotEditorStroke? {
        guard let editor = textView else {return nil}
        editor.unmarkText()
        guard var stroke=textStroke else{return nil}
        stroke.layoutText(editor.string); stroke.isEditingPreview = false
        return stroke
    }
    func beginParameterChange() {
        guard !document.isGrouping else { return }
        if let stroke = currentTextVersion() { document.commit(stroke) }
        document.beginOperation()
        if textView != nil { textDidChange(Notification(name: NSText.didChangeNotification)) }
    }
    func endParameterChange() {
        guard document.isGrouping else { return }
        if let stroke = currentTextVersion() { document.commit(stroke) }
        document.endOperation()
        if textView != nil { textDidChange(Notification(name: NSText.didChangeNotification)) }
        synchronizeTextChrome(); needsDisplay = true; onChange?()
    }
    /// refreshAllSizeAndDrawRect: syncs the current annotation with the native text view and records a new history revision.
    func updateSelected(_ change: (inout ScreenshotEditorStroke) -> Void) {
        if placingAnnotation, var preview = document.preview {
            change(&preview); preview.layoutText(preview.text)
            document.preview = preview; updateTextChrome(for: preview); needsDisplay = true
            return
        }
        if var stroke = textStroke, let editor = textView {
            let discrete = !document.isGrouping
            if discrete { beginParameterChange() }
            change(&stroke); textStroke = stroke
            applyTextAppearance(stroke, to: editor)
            textDidChange(Notification(name: NSText.didChangeNotification))
            if discrete { endParameterChange() }
            return
        }
        guard let selected, var stroke = document.visible.first(where: { $0.id == selected }) else { return }
        change(&stroke)
        if stroke.tool == .text { stroke.layoutText(stroke.text) }
        document.commit(stroke); synchronizeTextChrome(); needsDisplay = true; onChange?()
    }
    func textDidChange(_ notification: Notification) {
        guard let editor = textView, var stroke = textStroke else { return }
        // Include marked text in size calculation without replacing textStorage, clearing marked range, or committing history.
        stroke.layoutText(editor.string)
        textStroke = stroke
        let containerSize=CGSize(width:stroke.textBoxWidth ?? stroke.rect.width,height:CGFloat.greatestFiniteMagnitude)
        // TextKit 1 can resize width while preserving IME composition; auto-width grows horizontally first while manual width stays fixed.
        if editor.textContainer?.containerSize != containerSize {editor.textContainer?.containerSize=containerSize}
        if editor.frame != stroke.textGlyphFrame {editor.frame=stroke.textGlyphFrame}
        var preview = stroke; preview.text = ""; preview.isEditingPreview = true
        document.preview = preview
        updateTextChrome(for: stroke); needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking); pointerTracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { setPointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if placingAnnotation { updateAnnotationPreview(at: point) }
        else { setPointer(at: point) }
    }
    func editCursor(at point: CGPoint) -> ScreenshotEditCursor {
        guard bounds.contains(point) else { return .idle }
        if outputCornerRadius > 0, outputClip.path?.contains(point) == false { return .idle }
        if let editor = textView, editor.frame.contains(point) { return .text }
        if document.visible.contains(where: { $0.tool == .text && $0.rect.contains(point) && !$0.hitsMarker(point) }) { return .text }
        if let selected, let stroke = document.visible.first(where: { $0.id == selected }) {
            if stroke.tool == .text {
                let f = stroke.textDecorationFrame
                if abs(point.y-f.midY) <= Design.AnnotationEditor.handleHeight, min(abs(point.x-f.minX), abs(point.x-f.maxX)) <= Design.ScreenshotEditor.handleSize { return .horizontal }
            } else if let index = handles(stroke).firstIndex(where: { hypot(point.x-$0.x, point.y-$0.y) <= Design.ScreenshotEditor.handleSize }) {
                if stroke.tool == .line || stroke.tool == .arrow || stroke.tool == .pencil { return .move }
                switch index { case 1, 5: return .vertical; case 3, 7: return .horizontal; case 0, 4: return .diagonalUp; default: return .diagonalDown }
            }
        }
        if document.visible.reversed().contains(where: { ScreenshotEditorGeometry.hit(point, stroke: $0) || (($0.tool == .rectangle || $0.tool == .ellipse) && ScreenshotEditorGeometry.path($0).contains(point)) }) { return .move }
        return tool == nil ? (onRegionDragBegan == nil ? .idle : .move) : .drawing
    }
    private func updateAnnotationPreview(at point: CGPoint) {
        guard var stroke = document.preview else { return }
        stroke.translateText(to: point)
        stroke.textMaximumWidth = min(Design.AnnotationEditor.maximumAutoWidth, bounds.width - stroke.start.x - Design.AnnotationEditor.inset)
        stroke.layoutText(stroke.text)
        document.preview = stroke
        updateTextChrome(for: stroke)
        needsDisplay = true
    }
    private func updateTextChrome(for stroke: ScreenshotEditorStroke) {
        textChrome.frame = stroke.textEditorFrame
        addSubview(textChrome, positioned: .above, relativeTo: layersOverlay)
        textChrome.needsDisplay = true
        window?.invalidateCursorRects(for: textChrome)
    }
    private func synchronizeTextChrome() {
        if placingAnnotation, let stroke = document.preview { updateTextChrome(for: stroke) }
        else if let stroke = textStroke { updateTextChrome(for: stroke) }
        else if let selected, let stroke = document.visible.first(where: { $0.id == selected && $0.tool == .text }) { updateTextChrome(for: stroke) }
        else { textChrome.removeFromSuperview() }
    }
    private func resizeText(by delta: CGFloat) {
        guard var stroke = textResizeBaseline else { return }
        let old = stroke.textBoxWidth ?? max(Design.AnnotationEditor.minimumWidth, stroke.rect.width)
        let changed = max(Design.AnnotationEditor.minimumWidth, old + (resizingTextLeft ? -delta : delta))
        if resizingTextLeft { stroke.start.x += old - changed }
        stroke.textBoxWidth = changed; stroke.textWidthIsManual = true; stroke.layoutText(stroke.text)
        if resizingWhileEditing, let editor = textView {
            textStroke = stroke
            editor.textContainer?.containerSize = CGSize(width: stroke.textBoxWidth ?? changed, height: .greatestFiniteMagnitude)
            editor.frame = stroke.textGlyphFrame
            var preview = stroke; preview.text = ""; preview.isEditingPreview = true
            document.preview = preview
        } else { document.preview = stroke }
        synchronizeTextChrome(); needsDisplay = true
    }
    func commitText() {
        if placingAnnotation {
            placingAnnotation = false; document.preview = nil; textChrome.removeFromSuperview(); needsDisplay = true
        }
        guard let editor = textView else {return}
        editor.unmarkText()
        guard var stroke=textStroke else{return}
        stroke.layoutText(editor.string)
        stroke.isEditingPreview = false
        document.commit(stroke); selected = stroke.id
        editor.removeFromSuperview(); textView = nil; textStroke = nil
        synchronizeTextChrome()
        needsDisplay = true; onChange?()
    }
}
