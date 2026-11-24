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
        let panel = TranslationPanel(contentRect: NSRect(x: 0, y: 0, width: TranslationPanelSize.defaultWidth, height: 440),
                                 styleMask: [.titled, .closable, .resizable],
                                 backing: .buffered, defer: false)
        self.panel = panel
        panel.title = "Seven"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // 空的紧凑工具栏把标题栏从 32 加高到 40，关闭按钮与右侧图标仍在同一中线上；
        // 图标距窗口顶与距输入框都约 14，上下相等且不拥挤。
        let toolbar = NSToolbar(identifier: "SevenTranslationPanelToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        panel.toolbar = toolbar
        panel.toolbarStyle = .unifiedCompact
        panel.isReleasedWhenClosed = false
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
        // 默认宽度改窄后换新名称，旧的 570 宽记录不再恢复。
        // 先恢复上次的位置与宽度；只有从未记录过时才居中（之前恢复后又被居中覆盖）。
        hasRememberedPanelPosition = panel.setFrameUsingName(Self.panelFrameName)
        panel.setFrameAutosaveName(Self.panelFrameName)
        if !hasRememberedPanelPosition { panel.center() }
        return panel
    }

    @objc func showPanel() {
        inputReplacement.cancel()
        presentPanel(near: NSEvent.mouseLocation)
    }

    internal func presentPanel(near anchor: NSPoint, avoiding exclusion: NSRect? = nil) {
        let panel = setupTranslationPanel()
        if !(model.pinned && panel.isVisible) {
            // 记住上次位置：第一次出现在鼠标旁，之后用户拖到哪里下次就在哪里。
            // 跟随鼠标：每次出现在鼠标旁（选中文字翻译时避开选区）。宽度都保持用户上次的宽度。
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
            guard let self, let panel, PanelVisibilityPolicy.shouldHide(
                isKeyWindow: applicationInactive ? false : panel.isKeyWindow,
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
