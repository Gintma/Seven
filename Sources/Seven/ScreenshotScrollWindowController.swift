import AppKit
import CoreGraphics

enum ScreenshotScrollAction { case edit, copy, save, ocr, pin }

@MainActor protocol ScreenshotScrollEventMonitoring {
    func addGlobal(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) -> Any?
    func addLocal(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) -> Any?
    func remove(_ monitor: Any)
}

@MainActor struct ScreenshotScrollSystemEvents: ScreenshotScrollEventMonitoring {
    func addGlobal(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
    }
    func addLocal(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
    }
    func remove(_ monitor: Any) { NSEvent.removeMonitor(monitor) }
}

private actor ScreenshotScrollProcessor {
    private var matcher: ScreenshotScrollMatcher?
    private var cachedPreview: CGImage?
    private var cachedPreviewSize: CGSize?
    func consume(_ image: CGImage, previewSize: CGSize, direction: Int) throws -> (ScreenshotScrollSample, Int, CGImage?, ScreenshotScrollMatchInfo) {
        try Task.checkCancellation()
        let frame = try ScreenshotScrollFrame(image: image)
        try Task.checkCancellation()
        let result: ScreenshotScrollSample
        let isInitial = matcher == nil
        if var current = matcher {
            result = current.consume(frame, directionHint: direction)
            try Task.checkCancellation()
            matcher = current
        } else { matcher = ScreenshotScrollMatcher(initial: frame); result = .unchanged }
        let outputChanged: Bool
        if case .addedPixels = result { outputChanged = true } else { outputChanged = false }
        // Redraw the full image only when output or display size changes; reuse the bitmap on revisits and keep the current preview when idle or failed.
        let sizeChanged = cachedPreviewSize != previewSize
        if isInitial || outputChanged || sizeChanged {
            cachedPreview = matcher?.previewImage(maximumSize: previewSize)
            cachedPreviewSize = previewSize
        }
        let thumbnail: CGImage?
        if isInitial || outputChanged || sizeChanged || result == .movedWithinRange { thumbnail = cachedPreview } else { thumbnail = nil }
        return (result, matcher?.outputHeight ?? frame.height, thumbnail, matcher?.matchInfo ?? .init())
    }
    func finish() -> CGImage? { matcher?.image }
}

/// Covers only the border, toolbar, and external thumbnail; the selection region stays pass-through so the target app scrolls normally.
/// border acts as the exclusion sentinel beneath all capture UI so capture belowWindow never captures our own toolbar or thumbnail.
@MainActor final class ScreenshotScrollWindowController: NSWindowController, NSWindowDelegate, ThemeApplying {
    let sessionID: UUID
    private let rect: CGRect
    private let screenFrame: CGRect
    private let previewScreen: CGRect
    private let previewScale: CGFloat
    private let capture: (CGRect, CGWindowID) -> CGImage?
    private let captureBackground: (CGRect, CGWindowID) -> CGImage?
    private let completed: (NSImage) -> Void
    private let trace: ScreenshotScrollTrace?
    private var sequence = 0
    private var directionHint = 0
    private var processor = ScreenshotScrollProcessor()
    private var sharing:ScreenshotSharingSession?
    private(set) var sharingServiceActive=false
    private var sharingTask:Task<Void,Never>?
    private let playCompletionSound:()->Void
    private let toolbarPreferences:ScreenshotToolbarPreferences
    private var toolbarObserver:NSObjectProtocol?
    private var actionButtons:[ScreenshotToolbarAction:NSButton]=[:]
    private let dragButton = ScreenshotToolbarDragButton()
    private let toolbar = ScreenshotEditorToolbar(compactStatus: true)
    private let toolbarPanel = ScreenshotEditorToolsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let statusPanel = ScreenshotEditorToolsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let previewPanel = ScreenshotEditorToolsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let preview = ScreenshotScrollPreviewImage()
    private let previewScroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: L10n.text("scrollUpOrDownInsideTheSelection"))
    private let progress = NSProgressIndicator()
    private var outputButtons: [NSButton] = []
    private var globalMonitor: Any?, localMonitor: Any?
    private var escapeMonitor: Any?
    private let events: any ScreenshotScrollEventMonitoring
    private var timer: Timer?
    private var schedulesSamples = false
    private(set) var sampling: Task<Void, Never>?
    private var finishing: Task<Void, Never>?
    private var generation = UUID()
    private var stopped = false
    private var delivered = false, cleanedUp = false
    private var needsRecovery = false
    private var failureSince: TimeInterval?
    private var lastActivity = Date.distantPast
    private var scale: CGFloat = 1
    private var dragOrigin = CGPoint.zero
    private(set) var outputAction: ScreenshotScrollAction = .edit
    private(set) var backgroundFrame: FrozenScreenshotFrame?
    var isCapturing: Bool { !stopped }

    init(rect: CGRect, sessionID: UUID = UUID(),
         capture: ((CGRect, CGWindowID) -> CGImage?)? = nil,
         captureBackground: ((CGRect, CGWindowID) -> CGImage?)? = nil,
         diagnostics: ScreenshotScrollTrace? = nil,
         toolbarPreferences:ScreenshotToolbarPreferences? = nil,
         events: (any ScreenshotScrollEventMonitoring)? = nil,
         completed: @escaping (NSImage) -> Void) {
        self.events = events ?? ScreenshotScrollSystemEvents()
        playCompletionSound=capture == nil ? {if ScreenshotCapturePreferences(defaults:.standard).completionSound {ScreenshotCompletionSound.play()}}:{}
        self.toolbarPreferences=toolbarPreferences ?? (capture == nil ? .shared:ScreenshotToolbarPreferences())
        self.rect = rect; self.sessionID = sessionID; self.completed = completed
        trace = diagnostics ?? (capture == nil ? ScreenshotScrollTrace.start(defaults: .standard) : nil)
        self.capture = capture ?? { FrozenSystemImage.capture(rect: $0, options: .optionOnScreenBelowWindow, windowID: $1) }
        // Tests injecting a mock sampling backend must never trigger real screen capture.
        self.captureBackground = captureBackground ?? capture ?? { FrozenSystemImage.capture(rect: $0, options: .optionOnScreenBelowWindow, windowID: $1) }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) })
        screenFrame = screen?.frame ?? rect
        previewScreen = screen?.visibleFrame ?? rect
        previewScale = screen?.backingScaleFactor ?? 1
        let border = NSPanel(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        border.title = L10n.text("scrollingScreenshotArea"); border.isReleasedWhenClosed = false
        border.level = ScreenshotPresentation.overlayLevel; border.isOpaque = false; border.backgroundColor = ThemePalette.clear
        border.hasShadow = false; border.hidesOnDeactivate = false; border.ignoresMouseEvents = true; border.animationBehavior = .none
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        border.contentView = ScreenshotScrollBorder(frame: CGRect(origin: .zero, size: screenFrame.size), rect: rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY))
        super.init(window: border)
        border.delegate = self
        toolbarPanel.title = L10n.text("scrollingScreenshotToolbar"); statusPanel.title = L10n.text("scrollingScreenshotStatus"); previewPanel.title = L10n.text("liveScrollingScreenshotPreview")
        for panel in [toolbarPanel, statusPanel, previewPanel] {
            panel.isReleasedWhenClosed = false; panel.animationBehavior = .none; panel.becomesKeyOnlyIfNeeded = true
            panel.isOpaque = false; panel.backgroundColor = ThemePalette.clear
            panel.hasShadow = false; panel.hidesOnDeactivate = false; panel.level = NSWindow.Level(rawValue: border.level.rawValue+1)
            panel.collectionBehavior = border.collectionBehavior
            border.addChildWindow(panel, ordered: .above)
        }
        for (symbol, title, action) in [
            ("square.and.pencil", L10n.text("editScrollingScreenshot"), #selector(editImage)), ("arrow.counterclockwise", L10n.text("resetScrollingScreenshot"), #selector(resetCapture)),
            ("text.viewfinder", L10n.text("recognizeText"), #selector(ocrImage)), ("square.and.arrow.down", L10n.text("saveScreenshot"), #selector(saveImage)),
            ("square.and.arrow.up", L10n.text("share"), #selector(shareImage(_:))), ("pin", L10n.text("pinImage"), #selector(pinImage)), ("xmark", L10n.text("exitScrollingScreenshot"), #selector(cancelCapture)),
            ("checkmark", L10n.text("capture.finishAndCopy"), #selector(copyImage))
        ] {
            let button = ScreenshotToolbarButton(symbol: symbol, title: title, target: self, action: action)
            if action != #selector(cancelCapture) { outputButtons.append(button) }
            toolbar.primary.addArrangedSubview(button)
            let kind:ScreenshotToolbarAction=action == #selector(editImage) ? .edit:action == #selector(resetCapture) ? .reset:action == #selector(ocrImage) ? .ocr:action == #selector(saveImage) ? .save:action == #selector(shareImage(_:)) ? .share:action == #selector(pinImage) ? .pin:action == #selector(cancelCapture) ? .cancel:.copy
            actionButtons[kind]=button
        }
        let drag = dragButton
        drag.onDragBegan = { [weak self] in self?.dragOrigin = self?.toolbarPanel.frame.origin ?? .zero }
        drag.onDrag = { [weak self] delta in
            guard let self else { return }
            let origin = CGPoint(x: self.dragOrigin.x+delta.width, y: self.dragOrigin.y+delta.height)
            self.toolbarPanel.setFrameOrigin(ScreenshotScrollLayout.clamped(origin, size: self.toolbarPanel.frame.size, to: self.screenFrame))
            self.positionPreview()
        }
        toolbar.primary.addArrangedSubview(drag);actionButtons[.drag]=drag
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        progress.widthAnchor.constraint(equalToConstant: Design.Icon.action).isActive = true
        progress.heightAnchor.constraint(equalToConstant: Design.Icon.action).isActive = true
        statusLabel.font = Design.Text.note.nsFont
        statusLabel.setAccessibilityLabel(L10n.text("scrollingScreenshotStatus"))
        statusLabel.alignment = .center
        toolbar.options.addArrangedSubview(statusLabel)
        statusLabel.lineBreakMode = .byTruncatingTail
        toolbar.fitVisibleContent(maximumOptionsWidth: previewScreen.width - Design.Space.s*2)
        if let statusBar = toolbar.arrangedSubviews.last {
            toolbar.removeArrangedSubview(statusBar); statusBar.removeFromSuperview()
            statusPanel.contentView = statusBar; statusPanel.setContentSize(statusBar.fittingSize)
        }
        statusPanel.ignoresMouseEvents = true
        toolbarPanel.contentView = toolbar; toolbarPanel.setContentSize(toolbar.fittingSize)
        preview.focusRingType = .none; previewScroll.focusRingType = .none
        preview.imageScaling = .scaleProportionallyDown; preview.setAccessibilityLabel(L10n.text("fullStitchedScreenshot"))
        let surface = ScreenshotScrollPreview(frame: .zero)
        previewScroll.documentView = preview
        previewScroll.hasVerticalScroller = true; previewScroll.autohidesScrollers = true
        previewScroll.drawsBackground = false; OverlayScrollerPolicy.configure(previewScroll)
        previewScroll.setAccessibilityLabel(L10n.text("scrollingScreenshotPreviewScrollToViewIt"))
        previewScroll.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(previewScroll)
        NSLayoutConstraint.activate([
            previewScroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: Design.Space.s),
            previewScroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -Design.Space.s),
            previewScroll.topAnchor.constraint(equalTo: surface.topAnchor, constant: Design.Space.s),
            previewScroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -Design.Space.s)
        ])
        previewPanel.contentView = surface; previewPanel.ignoresMouseEvents = false
        ThemeManager.shared.register(self)
        layoutPanels();updateToolbar()
        toolbarObserver=NotificationCenter.default.addObserver(forName:ScreenshotToolbarPreferences.changed,object:self.toolbarPreferences,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.updateToolbar()}}
        trace?.record(.started,generation:generation,rect:rect)
    }
    required init?(coder: NSCoder) { nil }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        toolbarPanel.orderFrontRegardless()
        statusPanel.orderFrontRegardless()
        if !previewPanel.frame.isEmpty { previewPanel.orderFrontRegardless() }
        if !schedulesSamples && !stopped {
            schedulesSamples = true
            globalMonitor = events.addGlobal(matching: .scrollWheel) { [weak self] event in self?.wheel(event) }
            // Keep focus in the target app; this monitor handles only cancellation and runs no tool shortcuts.
            escapeMonitor = events.addGlobal(matching: .keyDown) { [weak self] event in
                _ = self?.cancelOnEscape(event)
            }
            localMonitor = events.addLocal(matching: [.scrollWheel, .keyDown]) { [weak self] event in
                if event.type == .scrollWheel { self?.wheel(event) }
                else if let self {
                    if self.cancelOnEscape(event) { return nil }
                    if event.window === self.toolbarPanel, self.performShortcut(event) {return nil}
                }
                return event
            }
            // Wait for the old editor overlay to exit before the first frame; schedule subsequent frames from each frame's actual start time so a 100ms grid does not inflate intervals to 200ms.
            scheduleNextSample(after: ScreenshotScrollPolicy.sampleInterval)
        }
    }
    private func cancelOnEscape(_ event: NSEvent) -> Bool {
        guard !stopped, !sharingServiceActive, event.type == .keyDown, event.keyCode == 53,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              NSApp.modalWindow == nil, window?.attachedSheet == nil, toolbarPanel.attachedSheet == nil else { return false }
        close()
        return true
    }
    func refreshInterfaceLanguage() {
        window?.title = L10n.text("scrollingScreenshotArea")
        toolbarPanel.title = L10n.text("scrollingScreenshotToolbar")
        statusPanel.title = L10n.text("scrollingScreenshotStatus")
        previewPanel.title = L10n.text("liveScrollingScreenshotPreview")
        statusLabel.setAccessibilityLabel(L10n.text("scrollingScreenshotStatus"))
        preview.setAccessibilityLabel(L10n.text("fullStitchedScreenshot"))
        previewScroll.setAccessibilityLabel(L10n.text("scrollingScreenshotPreviewScrollToViewIt"))
        statusLabel.stringValue = statusMessage.text
        dragButton.updateLocalizedLabel(L10n.text("dragToolbar"))
        updateToolbar()
    }

    private func updateToolbar() {
        for (action,button) in actionButtons {
            button.isHidden = !toolbarPreferences.item(action).visible
            let title: String
            switch action {
            case .copy: title = L10n.text("capture.finishAndCopy")
            case .edit: title = L10n.text("editScrollingScreenshot")
            case .cancel: title = L10n.text("exitScrollingScreenshot")
            default: title = action.title
            }
            let key = toolbarPreferences.hint(action)
            if button.title != title {
                let imagePosition = button.imagePosition
                button.title = title
                button.imagePosition = imagePosition
            }
            button.updateLocalizedLabel(title, toolTip: key.isEmpty ? title : L10n.format("shortcutHint", title, key))
        }
        toolbar.fitVisibleContent(maximumOptionsWidth:previewScreen.width-Design.Space.s*2)
        toolbarPanel.setContentSize(toolbar.fittingSize)
        toolbarPanel.setFrameOrigin(ScreenshotScrollLayout.clamped(toolbarPanel.frame.origin,size:toolbarPanel.frame.size,to:screenFrame))
        positionStatus();if preview.image != nil {positionPreview()}
    }
    @discardableResult func performShortcut(_ event:NSEvent)->Bool {
        guard let action=toolbarPreferences.action(for:event,context:.longCapture) else{return false}
        if event.isARepeat {return true}
        switch action {
        case .edit:editImage()
        case .reset:resetCapture()
        case .ocr:ocrImage()
        case .share:if let button=actionButtons[.share] {shareImage(button)}
        case .save:saveImage()
        case .pin:pinImage()
        case .copy:copyImage()
        case .cancel:cancelCapture()
        default:return false
        }
        return true
    }
    private func scheduleNextSample(after delay: TimeInterval) {
        guard schedulesSamples,!sharingServiceActive,!stopped else { return }
        timer?.invalidate()
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timer = nil; self?.tick() }
        }
        timer = next
        // Keep sampling active even when the main RunLoop enters tracking mode during tool menus or preview drags.
        RunLoop.main.add(next, forMode: .common)
    }
    private func layoutPanels() {
        let size = toolbarPanel.frame.size
        let origin = CGPoint(x: rect.maxX-size.width, y: rect.minY-size.height-Design.Space.s)
        let above = CGPoint(x: origin.x, y: rect.maxY+Design.Space.s)
        toolbarPanel.setFrameOrigin(ScreenshotScrollLayout.clamped(origin.y >= screenFrame.minY ? origin : above, size: size, to: screenFrame))
        positionStatus()
        previewPanel.setFrame(.zero, display: false) // Display at the actual image aspect ratio once the first frame arrives.
    }
    private func positionStatus() {
        guard let content = statusPanel.contentView else { return }
        statusPanel.setContentSize(content.fittingSize)
        let frame = ScreenshotScrollLayout.statusRect(size: statusPanel.frame.size, selection: rect, screen: previewScreen)
        statusPanel.setFrameOrigin(frame.origin)
    }
    private var pointerIsOverPreview: Bool { previewPanel.isVisible && previewPanel.frame.contains(NSEvent.mouseLocation) }
    func wheel(_ event: NSEvent) {
        guard !stopped,!sharingServiceActive, event.window !== previewPanel, rect.contains(NSEvent.mouseLocation), !pointerIsOverPreview else { return }
        if event.deltaY != 0 { directionHint = event.deltaY < 0 ? 1 : -1 }
        trace?.record(.wheel,generation:generation,wheelDeltaY:event.deltaY)
        lastActivity = Date()
    }
    func tick() {
        guard !stopped,!sharingServiceActive else { return }
        if sequence==0 || Date().timeIntervalSince(lastActivity) < ScreenshotScrollPolicy.activityTimeout {
            sample()
        } else { scheduleNextSample(after: ScreenshotScrollPolicy.sampleInterval) }
    }
    private func capturedFrame() -> CGImage? {
        guard let window, rect.width > 0 else { return nil }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let quartz = CGRect(x: rect.minX, y: primaryTop-rect.maxY, width: rect.width, height: rect.height)
        guard let image = capture(quartz, CGWindowID(window.windowNumber)) else { return nil }
        scale = CGFloat(image.width)/rect.width
        return image
    }
    func sample() {
        guard !stopped,!sharingServiceActive, sampling == nil else { return }
        timer?.invalidate(); timer = nil
        sequence += 1
        let frameID = sequence, started = ProcessInfo.processInfo.systemUptime
        trace?.record(.sampleStarted,sequence:frameID,generation:generation)
        guard let image = capturedFrame() else {
            trace?.record(.captureFailed,sequence:frameID,generation:generation)
            setStatus(.key("couldNotSampleTheAreaCheckScreen"), error: true)
            scheduleNextSample(after: ScreenshotScrollPolicy.delayUntilNextSample(elapsed: ProcessInfo.processInfo.systemUptime-started))
            return
        }
        let token = generation, processor = processor, direction = directionHint, trace = trace
        let area = ScreenshotScrollLayout.previewSpace(outside: rect, screen: previewScreen, avoiding: toolbarPanel.frame, alsoAvoiding: statusPanel.frame)
        let inset = Design.Space.s*2
        let pixelSize = CGSize(width: max(1, (area?.width ?? 1)-inset)*previewScale,
                               height: .greatestFiniteMagnitude)
        sampling = Task { [weak self] in
            do {
                let (result, height, thumbnail, info) = try await processor.consume(image, previewSize: pixelSize, direction: direction)
                guard let self, self.generation == token, !Task.isCancelled, !self.stopped else {
                    trace?.record(.discarded,sequence:frameID,generation:token); return
                }
                trace?.record(.sampleFinished,sequence:frameID,generation:token,pixelWidth:image.width,pixelHeight:image.height,
                    scale:Double(self.scale),elapsedMS:(ProcessInfo.processInfo.systemUptime-started)*1000,match:info)
                if self.sharingServiceActive {self.sampling=nil;return}
                if let thumbnail { self.updatePreview(thumbnail, info: info, frameHeight: image.height) }
                switch result {
                case .noMatch, .limitReached: self.preview.viewport = nil
                default:
                    let total = image.height + info.upper - info.lower
                    self.preview.viewport = CGRect(x: 0, y: CGFloat(info.position-info.lower)/CGFloat(total), width: 1, height: CGFloat(image.height)/CGFloat(total))
                }
                switch result {
                case .addedPixels:
                    self.needsRecovery = false; self.failureSince = nil
                    self.setStatus(.key("stitchedPxHigh", .text(String(height))))
                case .movedWithinRange:
                    self.needsRecovery = false; self.failureSince = nil
                    self.setStatus(.key("thisAreaIsAlreadyCapturedKeepScrolling"))
                case .noMatch:
                    self.needsRecovery = true
                    let now = ProcessInfo.processInfo.systemUptime
                    if self.failureSince == nil {self.failureSince = now}
                    let sustained = now-(self.failureSince ?? now)>=ScreenshotScrollPolicy.failureNoticeDelay
                    self.setStatus(sustained ? .key("noOverlapFoundReturnToACaptured") : .key("findingTheOverlapYourCaptureIsSafe"))
                case .limitReached:
                    self.setStatus(.key("theScreenshotHasReachedItsSizeLimit"))
                case .unchanged:
                    // Scroll events reach the target app asynchronously; do not mistake an unchanged frame for reaching the bottom.
                    if self.needsRecovery {
                        self.needsRecovery = false; self.failureSince = nil; self.setStatus(.key("foundTheSeamYouCanContinueScrolling"))
                    }
                }
                self.sampling = nil
                self.scheduleNextSample(after: ScreenshotScrollPolicy.delayUntilNextSample(elapsed: ProcessInfo.processInfo.systemUptime-started))
            } catch {
                trace?.record(.discarded,sequence:frameID,generation:token)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.sampling = nil
                if self.sharingServiceActive {return}
                self.setStatus(.key("couldNotProcessTheCurrentFrameThe"), error: true)
                self.scheduleNextSample(after: ScreenshotScrollPolicy.delayUntilNextSample(elapsed: ProcessInfo.processInfo.systemUptime-started))
            }
        }
    }
    private func updatePreview(_ image: CGImage, info: ScreenshotScrollMatchInfo, frameHeight: Int) {
        preview.image = NSImage(cgImage:image,size:CGSize(width:CGFloat(image.width)/previewScale,height:CGFloat(image.height)/previewScale))
        positionPreview()
        let maximum = max(0,preview.frame.height-previewScroll.contentSize.height)
        let y: CGFloat
        switch info.reason {
        case .extendedTop,.initial: y = 0
        case .extendedBottom: y = maximum
        case .withinRange where info.displacement != 0 || info.reference == .collectedViewport:
            let total = CGFloat(frameHeight+info.upper-info.lower)
            y = (CGFloat(info.position-info.lower)+CGFloat(frameHeight)/2)/max(1,total)*preview.frame.height-previewScroll.contentSize.height/2
        default: return // Do not repeatedly snap the user back to the end on idle frames while browsing the preview.
        }
        previewScroll.contentView.scroll(to:CGPoint(x:0,y:min(max(0,y),maximum)))
        previewScroll.reflectScrolledClipView(previewScroll.contentView)
    }
    private func positionPreview() {
        guard let image = preview.image,
              let space = ScreenshotScrollLayout.previewSpace(outside:rect,screen:previewScreen,avoiding:toolbarPanel.frame,alsoAvoiding:statusPanel.frame),
              let frame = ScreenshotScrollLayout.previewRect(imageSize:image.size,within:space,beside:rect) else {
            previewPanel.orderOut(nil); return
        }
        let previousY = previewScroll.contentView.bounds.minY
        previewPanel.setFrame(frame,display:true)
        previewPanel.contentView?.layoutSubtreeIfNeeded()
        let width = max(1,frame.width-Design.Space.s*2)
        preview.frame = CGRect(x:0,y:0,width:width,height:width*image.size.height/max(1,image.size.width))
        previewScroll.contentView.scroll(to:CGPoint(x:0,y:min(previousY,max(0,preview.frame.height-previewScroll.contentSize.height))))
        if previewPanel.parent !== window,let window { window.addChildWindow(previewPanel,ordered:.above) }
        if window?.isVisible == true { previewPanel.orderFrontRegardless() }
    }
    private var palette = ThemePalette.system
    private var statusIsError = false

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        statusLabel.textColor = statusIsError ? palette.error : palette.ink
    }

    private var statusMessage = LocalizedMessage.key("scrollUpOrDownInsideTheSelection")

    private func setStatus(_ message: LocalizedMessage, error: Bool = false) {
        statusMessage = message
        statusIsError = error
        statusLabel.stringValue = message.text
        statusLabel.textColor = error ? palette.error : palette.ink
        toolbar.fitVisibleContent(maximumOptionsWidth: previewScreen.width - Design.Space.s*2); toolbarPanel.setContentSize(toolbar.fittingSize)
        positionStatus()
        toolbarPanel.setFrameOrigin(ScreenshotScrollLayout.clamped(toolbarPanel.frame.origin, size: toolbarPanel.frame.size, to: screenFrame))
        positionPreview()
    }
    @objc func resetCapture() {
        guard !stopped else { return }
        generation = UUID(); sharingTask?.cancel();sharingTask=nil;directionHint = 0; sampling?.cancel(); sampling = nil
        trace?.record(.reset,generation:generation)
        processor = ScreenshotScrollProcessor(); needsRecovery = false; failureSince = nil
        preview.image = nil; preview.viewport = nil; lastActivity = .distantPast; setStatus(.key("captureResetStitchingWillStartFromThe"))
        sample()
    }
    @objc private func shareImage(_ sender:NSButton) {
        guard !stopped,sharingTask == nil else{return}
        let token=generation,processor=processor
        sharingTask=Task { [weak self,weak sender] in
            let image=await processor.finish()
            guard let self,!self.stopped,!Task.isCancelled,self.generation == token else{return}
            self.sharingTask=nil
            if let image,let sender {
                let output=NSImage(cgImage:image,size:CGSize(width:CGFloat(image.width)/self.scale,height:CGFloat(image.height)/self.scale))
                ScreenshotSharingSession.present(output,from:sender,current:&self.sharing,activityChanged:{ [weak self] active in self?.setSharingServiceActive(active) },serviceChosen:{ [weak self] in
                    guard let self,!self.stopped else{return}
                    self.delivered=true;self.playCompletionSound();self.close()
                })
            }
        }
    }
    func setSharingServiceActive(_ active:Bool) {
        guard !stopped else{return}
        sharingServiceActive=active
        if active {timer?.invalidate();timer=nil}
        else {lastActivity = .distantPast;directionHint=0;scheduleNextSample(after:ScreenshotScrollPolicy.sampleInterval)}
    }
    @objc private func editImage() { finish(.edit) }
    @objc private func copyImage() { finish(.copy) }
    @objc private func saveImage() { finish(.save) }
    @objc private func ocrImage() { finish(.ocr) }
    @objc private func pinImage() { finish(.pin) }
    private func finish(_ action: ScreenshotScrollAction) {
        guard !stopped else { return }
        stopped = true; outputAction = action; removeInputs()
        toolbar.options.insertArrangedSubview(progress, at: 0)
        progress.startAnimation(nil); setStatus(.key("finishingScrollingScreenshot")); outputButtons.forEach { $0.isEnabled = false }
        let token = generation, processor = processor, inFlight = sampling
        finishing = Task { [weak self] in
            await inFlight?.value
            guard let self, self.generation == token, !Task.isCancelled else { return }
            if let frame = self.capturedFrame() {
                self.sequence += 1
                let frameID = self.sequence, started = ProcessInfo.processInfo.systemUptime
                self.trace?.record(.sampleStarted,sequence:frameID,generation:token)
                do {
                    let (_,_,_,info) = try await processor.consume(frame,previewSize:.zero,direction:self.directionHint)
                    guard !Task.isCancelled,self.generation == token else { self.trace?.record(.discarded,sequence:frameID,generation:token); return }
                    self.trace?.record(.sampleFinished,sequence:frameID,generation:token,pixelWidth:frame.width,pixelHeight:frame.height,
                        scale:Double(self.scale),elapsedMS:(ProcessInfo.processInfo.systemUptime-started)*1000,match:info)
                } catch { self.trace?.record(.discarded,sequence:frameID,generation:token) }
            }
            guard !Task.isCancelled else { return }
            let image = await processor.finish()
            guard !Task.isCancelled, self.generation == token else { return }
            self.progress.stopAnimation(nil)
            self.toolbar.options.removeArrangedSubview(self.progress); self.progress.removeFromSuperview()
            if let image {
                if let window = self.window {
                    let quartz = CGRect(x: self.screenFrame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0)-self.screenFrame.maxY, width: self.screenFrame.width, height: self.screenFrame.height)
                    if let background = self.captureBackground(quartz, CGWindowID(window.windowNumber)) { self.backgroundFrame = .init(screenFrame: self.screenFrame, image: background) }
                }
                self.trace?.record(.finished,generation:token,pixelWidth:image.width,pixelHeight:image.height)
                await self.trace?.flushed()
                guard !Task.isCancelled,self.generation == token else { return }
                self.delivered = true
                self.completed(NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width)/self.scale, height: CGFloat(image.height)/self.scale)))
                self.close()
            } else { self.setStatus(.key("noScreenshotIsAvailableExitAndSelect"), error: true) }
        }
    }
    @objc private func cancelCapture() { close() }
    override func close() { cleanUp(); super.close() }
    func windowWillClose(_ notification: Notification) { cleanUp() }
    private func cleanUp() {
        guard !cleanedUp else { return }
        cleanedUp = true
        if !delivered { trace?.record(.cancelled,generation:generation) }
        stopped = true; generation = UUID(); removeInputs()
        if let toolbarObserver {NotificationCenter.default.removeObserver(toolbarObserver);self.toolbarObserver=nil}
        sharingTask?.cancel();sharingTask=nil;sampling?.cancel(); finishing?.cancel(); sampling = nil; finishing = nil
        for panel in [toolbarPanel, statusPanel, previewPanel] { window?.removeChildWindow(panel); panel.close() }
    }
    private func removeInputs() {
        schedulesSamples = false
        timer?.invalidate(); timer = nil
        if let globalMonitor { events.remove(globalMonitor); self.globalMonitor = nil }
        if let escapeMonitor { events.remove(escapeMonitor); self.escapeMonitor = nil }
        if let localMonitor { events.remove(localMonitor); self.localMonitor = nil }
    }
}

/// Prefer placing outside the selection; if the minimum width does not fit, tuck against the inner edge while staying on-screen and clear of the toolbar.
enum ScreenshotScrollLayout {
    static func clamped(_ point:CGPoint,size:CGSize,to screen:CGRect)->CGPoint {
        let m = Design.Space.s
        return CGPoint(x:min(max(point.x,screen.minX+m),max(screen.minX+m,screen.maxX-size.width-m)),
                       y:min(max(point.y,screen.minY+m),max(screen.minY+m,screen.maxY-size.height-m)))
    }
    /// Matches the standard screenshot size bar position: prefer above the selection's top-left, moving inside the top-left corner when space is tight.
    static func statusRect(size: CGSize, selection: CGRect, screen: CGRect) -> CGRect {
        let margin = Design.Space.s
        let above = selection.maxY + margin
        let y = above + size.height <= screen.maxY - margin ? above : selection.maxY - size.height - margin
        return CGRect(origin: clamped(CGPoint(x: selection.minX, y: y), size: size, to: screen), size: size)
    }
    private static func pieces(in area:CGRect,avoiding toolbar:CGRect)->[CGRect] {
        guard !area.isNull,!area.isEmpty else { return [] }
        let m = Design.Space.s,hit = toolbar.insetBy(dx:-m,dy:-m).intersection(area)
        if toolbar.isEmpty || hit.isNull { return [area] }
        return [
            CGRect(x:area.minX,y:hit.maxY,width:area.width,height:max(0,area.maxY-hit.maxY)),
            CGRect(x:area.minX,y:area.minY,width:area.width,height:max(0,hit.minY-area.minY)),
            CGRect(x:area.minX,y:area.minY,width:max(0,hit.minX-area.minX),height:area.height),
            CGRect(x:hit.maxX,y:area.minY,width:max(0,area.maxX-hit.maxX),height:area.height)
        ]
    }
    static func previewSpace(outside rect:CGRect,screen:CGRect,avoiding toolbar:CGRect = .zero,alsoAvoiding status:CGRect = .zero)->CGRect? {
        let m = Design.Space.s,safe = screen.insetBy(dx:m,dy:m)
        let minimum = Design.ScreenshotScroll.minimumPreviewWidth+2*m
        let slots = [
            CGRect(x:rect.maxX+m,y:safe.minY,width:max(0,safe.maxX-rect.maxX-m),height:safe.height),
            CGRect(x:safe.minX,y:safe.minY,width:max(0,rect.minX-m-safe.minX),height:safe.height),
            CGRect(x:safe.minX,y:rect.maxY+m,width:safe.width,height:max(0,safe.maxY-rect.maxY-m)),
            CGRect(x:safe.minX,y:safe.minY,width:safe.width,height:max(0,rect.minY-m-safe.minY))
        ]
        func fitting(_ area:CGRect)->[CGRect] {
            pieces(in:area.intersection(safe),avoiding:toolbar).flatMap { pieces(in:$0,avoiding:status) }.filter {
                $0.width>=minimum && $0.height>=Design.ScreenshotScroll.minimumPreviewSpace
            }
        }
        var options: [CGRect] = []
        for (index,slot) in slots.enumerated() {
            for area in fitting(slot).sorted(by: { $0.width*$0.height > $1.width*$1.height }) {
                let width = min(area.width,Design.ScreenshotScroll.previewWidth+2*m)
                let height = min(area.height,Design.ScreenshotScroll.previewHeight+2*m)
                let x = index == 0 ? area.minX : index == 1 ? area.maxX-width : min(max(rect.maxX-width,area.minX),area.maxX-width)
                let y = min(max(rect.maxY-height,area.minY),area.maxY-height)
                let candidate = CGRect(x:x,y:y,width:width,height:height)
                if width == Design.ScreenshotScroll.previewWidth+2*m && height == Design.ScreenshotScroll.previewHeight+2*m { return candidate }
                options.append(candidate)
            }
        }
        if let outside = options.max(by: { $0.width*$0.height < $1.width*$1.height }) { return outside }
        // Allow overflowing the selection edge when narrower than 160pt while maintaining the minimum width and clamping to the current screen.
        let inside = rect.intersection(safe).insetBy(dx:m,dy:m)
        let fallback = fitting(inside).isEmpty ? fitting(safe) : fitting(inside)
        guard let area = fallback.max(by: { $0.width*$0.height < $1.width*$1.height }) else { return nil }
        let width = min(area.width,Design.ScreenshotScroll.previewWidth+2*m)
        let height = min(area.height,Design.ScreenshotScroll.previewHeight+2*m)
        return CGRect(x:min(max(rect.maxX-width-m,area.minX),area.maxX-width),
                      y:min(max(rect.maxY-height-m,area.minY),area.maxY-height),width:width,height:height)
    }
    static func previewRect(imageSize:CGSize,within space:CGRect,beside rect:CGRect)->CGRect? {
        let m = Design.Space.s
        guard imageSize.width>0,imageSize.height>0,space.width>=Design.ScreenshotScroll.minimumPreviewWidth+2*m else { return nil }
        let width = min(space.width-2*m,Design.ScreenshotScroll.previewWidth)
        let height = min(space.height,width*imageSize.height/imageSize.width+2*m)
        let x = space.maxX<=rect.minX ? space.maxX-width-2*m : space.minX
        let y = min(max(rect.maxY-height,space.minY),space.maxY-height)
        return CGRect(x:x,y:y,width:width+2*m,height:height)
    }
}

final class ScreenshotScrollBorder: ThemedDrawingView {
    let rect: CGRect
    init(frame: CGRect, rect: CGRect) { self.rect = rect; super.init(frame: frame) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        FrozenCaptureMask.drawOverlay(in: bounds, revealing: rect)
        theme.captureAccent.setStroke()
        let path = NSBezierPath(rect:rect);path.lineWidth = Design.ScreenshotCapture.borderWidth;path.stroke()
        // The fixed capture region renders only L-shaped corner accents, with no handles, tracking areas, or resize/move interactions.
        let inside = min(Design.ScreenshotCapture.cornerInside,min(rect.width,rect.height)/2)
        let outside = Design.ScreenshotCapture.cornerOutside
        let corners = NSBezierPath()
        for (x,y,sx,sy) in [(rect.minX,rect.minY,CGFloat(1),CGFloat(1)),(rect.maxX,rect.minY,CGFloat(-1),CGFloat(1)),
                            (rect.minX,rect.maxY,CGFloat(1),CGFloat(-1)),(rect.maxX,rect.maxY,CGFloat(-1),CGFloat(-1))] {
            corners.move(to:CGPoint(x:x+sx*inside,y:y-sy*outside))
            corners.line(to:CGPoint(x:x-sx*outside,y:y-sy*outside))
            corners.line(to:CGPoint(x:x-sx*outside,y:y+sy*inside))
        }
        corners.lineWidth = Design.ScreenshotCapture.cornerWidth;corners.stroke()
    }
}
final class ScreenshotScrollPreview: ThemedDrawingView {
    override func draw(_ dirtyRect: NSRect) {
        theme.surfaceRaised.setFill()
        bounds.fill() // The image preview has square corners; do not reuse the toolbar's rounded chrome.
    }
}

/// Normalized coordinates span the full stitched image; overlays scroll with the document and clip naturally via NSClipView.
final class ScreenshotScrollPreviewImage: NSImageView, ThemeApplying {
    private var palette = ThemePalette.system

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { ThemeManager.shared.register(self) }
    }

    var viewport: CGRect? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    var viewportRect: CGRect? {
        guard let viewport else { return nil }
        return CGRect(x: bounds.minX + viewport.minX*bounds.width,
                      y: bounds.minY + viewport.minY*bounds.height,
                      width: viewport.width*bounds.width, height: viewport.height*bounds.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let viewportRect else { return }
        let line = Design.ScreenshotScroll.viewportLineWidth
        let box = viewportRect.insetBy(dx: line, dy: line)
        guard box.width > 0, box.height > 0 else { return }
        palette.accent.setStroke()
        let border = NSBezierPath(rect: box); border.lineWidth = line; border.stroke()
        let length = min(Design.ScreenshotScroll.viewportCornerLength, min(box.width, box.height)/2)
        let corners = NSBezierPath()
        for (x,y,sx,sy) in [(box.minX,box.minY,CGFloat(1),CGFloat(1)),(box.maxX,box.minY,CGFloat(-1),CGFloat(1)),
                            (box.minX,box.maxY,CGFloat(1),CGFloat(-1)),(box.maxX,box.maxY,CGFloat(-1),CGFloat(-1))] {
            corners.move(to: CGPoint(x:x+sx*length,y:y)); corners.line(to: CGPoint(x:x,y:y))
            corners.line(to: CGPoint(x:x,y:y+sy*length))
        }
        corners.lineWidth = Design.ScreenshotScroll.viewportCornerWidth; corners.stroke()
    }
}
