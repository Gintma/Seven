import AppKit

extension AppDelegate {

    func refreshPanelTitlebarLanguage() {
        for controller in panel?.titlebarAccessoryViewControllers ?? [] {
            (controller.view as? AppKitTitlebarControls)?.refreshInterfaceLanguage()
        }
    }

    @discardableResult
    internal func setupTranslationPanel() -> TranslationPanel {
        if let panel { return panel }
        let panel = TranslationPanel(model: model)
        self.panel = panel
        panel.title = "Seven"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // An empty compact toolbar increases titlebar height from 32 to 40 while keeping the close button and trailing icons aligned on the same centerline;
        // icons sit ~14 pt from both the window top and the input field, evenly spaced without crowding.
        let toolbar = NSToolbar(identifier: "SevenTranslationPanelToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        panel.toolbar = toolbar
        panel.toolbarStyle = .unifiedCompact
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.minSize = NSSize(width: TranslationPanelSize.minimumWidth, height: TranslationWindowLayoutPreferences.minimumPanelHeight)
        panel.configureWindowButtons()
        panel.delegate = self
        if let screen = NSScreen.main {
            model.updatePanelScreenHeight(screen.visibleFrame.height)
        }
        let translationViewController = AppKitTranslationViewController(model: model)
        translationViewController.onPreferredPanelHeightChange = { [weak self] height in
            guard height.isFinite, height > 0 else { return }
            self?.preferredPanelHeight = height
        }
        panel.contentViewController = translationViewController
        let titlebarAccessory = NSTitlebarAccessoryViewController()
        titlebarAccessory.layoutAttribute = .right
        titlebarAccessory.view = AppKitTitlebarControls(model: model)
        panel.addTitlebarAccessoryViewController(titlebarAccessory)
        // Renamed after narrowing the default width so legacy 570-wide saved frames are no longer restored.
        // Restore the last position and width first; only center if never saved before (previously centering overwrote the restored frame).
        hasRememberedPanelPosition = panel.setFrameUsingName(Self.panelFrameName)
        panel.setFrameAutosaveName(Self.panelFrameName)
        if !hasRememberedPanelPosition { panel.center() }
        return panel
    }

    @objc func showPanel() {
        inputReplacement.cancel()
        setupTranslationPanel().prepareForInputPresentation()
        presentPanel(near: NSEvent.mouseLocation)
    }

    internal func presentPanel(near anchor: NSPoint, avoiding exclusion: NSRect? = nil) {
        let panel = setupTranslationPanel()
        if !panel.isVisible {
            (panel.contentViewController as? AppKitTranslationViewController)?.reloadFromModel(animated: false)
        }
        if !(model.pinned && panel.isVisible) {
            // Remember last position: appears near the mouse initially, then reopens wherever the user dragged it.
            // Follow mouse: opens near the mouse each time (avoiding the text selection when translating selected text). Both modes preserve the last width.
            if PanelPlacementMode.stored() == .remember, hasRememberedPanelPosition {
                placePanelAtRememberedPosition(panel)
            } else {
                positionPanel(panel, near: anchor, avoiding: exclusion)
                hasRememberedPanelPosition = true
            }
        }
        if panel.isVisible, !panel.isOnActiveSpace { panel.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel(); return true
    }
    func windowDidResignKey(_ notification: Notification) {
        // Defer to let sheets and in-app transitions settle.
        hidePanelAfterFocusChange(applicationInactive: false)
    }
    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === panel,
              let screen = window.screen else { return }
        model.updatePanelScreenHeight(screen.visibleFrame.height)
        (window.contentViewController as? AppKitTranslationViewController)?.refreshWindowLayout(animated: false)
    }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === panel else { return frameSize }
        return PanelManualResizePolicy.widthOnly(
            proposed: frameSize,
            current: sender.frame.size
        )
    }
    func applicationDidResignActive(_ notification: Notification) {
        hidePanelAfterFocusChange(applicationInactive: true)
    }
    private func hidePanelAfterFocusChange(applicationInactive: Bool) {
        guard let panel else { return }
        DispatchQueue.main.async { [weak self, weak panel] in
            // Reopening or moving across Spaces may have already restored focus.
            guard let self, let panel, panel.isVisible, PanelVisibilityPolicy.shouldHide(
                isKeyWindow: panel.isKeyWindow && (!applicationInactive || NSApp.isActive),
                isPinned: self.model.pinned,
                hasAttachedSheet: panel.attachedSheet != nil,
                hasAnotherApplicationWindow: NSApp.keyWindow != nil && NSApp.keyWindow !== panel
            ) else { return }
            self.model.hide()
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.cancel()
        cancelSelectionWork()
        cancelScreenshotWork()
        return true
    }

    private func positionPanel(_ panel: TranslationPanel, near anchor: NSPoint, avoiding exclusion: NSRect? = nil) {
        guard let screen = screen(containing: anchor) else { return }
        model.updatePanelScreenHeight(screen.visibleFrame.height)
        let size = NSSize(
            width: panel.frame.width,
            height: fittedPanelHeight(for: screen)
        )
        panel.setFrame(
            PanelGeometry.frame(
                around: anchor,
                size: size,
                within: screen.visibleFrame,
                avoiding: exclusion
            ),
            display: panel.isVisible
        )
    }

    private func placePanelAtRememberedPosition(_ panel: TranslationPanel) {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard let fallbackScreen = screen(containing: NSEvent.mouseLocation) else { return }
        let target = PanelGeometry.screen(mostOverlapping: panel.frame, in: visibleFrames)
            .flatMap { frame in NSScreen.screens.first { $0.visibleFrame == frame } } ?? fallbackScreen
        model.updatePanelScreenHeight(target.visibleFrame.height)
        let frame = PanelGeometry.rememberedFrame(
            panel.frame,
            height: fittedPanelHeight(for: target),
            screens: visibleFrames,
            fallback: fallbackScreen.visibleFrame
        )
        panel.setFrame(frame, display: panel.isVisible)
    }

    private func fittedPanelHeight(for screen: NSScreen) -> CGFloat {
        let maximum = TranslationWindowLayoutPreferences.maximumPanelHeight(
            screenHeight: screen.visibleFrame.height,
            ratio: model.maximumWindowHeightRatio
        )
        let minimum = min(TranslationWindowLayoutPreferences.minimumPanelHeight, maximum)
        return min(max(preferredPanelHeight, minimum), maximum)
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

}
