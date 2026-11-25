import AppKit

extension AppDelegate {

    internal func setupStatusItem() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(named: "SevenMenu")
            ?? NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Seven")
        item.button?.image?.isTemplate = true
        item.button?.setAccessibilityLabel("Seven")
        item.button?.toolTip = "Seven"
        refreshStatusMenu()
    }

    private func refreshStatusMenu() {
        @discardableResult func add(_ title:String,_ action:Selector,_ manager:HotKeyManager? = nil)->NSMenuItem {
            let row=NSMenuItem(title:title,action:action,keyEquivalent:"")
            row.target=self;row.representedObject=manager
            StatusMenuShortcut.apply(manager?.isEnabled == true ? manager?.shortcut:nil,to:row)
            return row
        }
        selectionMenuItem=add(L10n.text("translateSelection"),#selector(selectionTranslate),hotKeyManager)
        screenshotMenuItem=add(L10n.text("translateScreenshot"),#selector(screenshotTranslate),screenshotHotKeyManager)
        inputMenuItem=add(L10n.text("translateTypedText"),#selector(showPanel),inputHotKeyManager)
        replacementMenuItem=add(L10n.text("translateAndReplace"),#selector(translateAndReplace),replacementHotKeyManager)
        let statusMenu = AppStatusMenu.build(
            translation: [selectionMenuItem, screenshotMenuItem, inputMenuItem, replacementMenuItem, add(L10n.text("history.title"),#selector(showHistory))],
            screenshots: [add(L10n.text("screenshot"),#selector(captureScreenshot),regionCaptureHotKeyManager),
                add(L10n.text("scrollingScreenshot"),#selector(captureLongScreenshot),imageEntryShortcuts.scroll),
                add(L10n.text("openLocalImage"),#selector(openLocalImage),imageEntryShortcuts.file),
                add(L10n.text("pinFromClipboard"),#selector(pinFromClipboard),clipboardPinHotKeyManager)],
            ocr: [add("OCR",#selector(captureOCR),ocrShortcuts.standard),
                add(L10n.text("clipboardOCR"),#selector(clipboardOCR),ocrShortcuts.clipboard),
                add(L10n.text("openOCRWindow"),#selector(openOCRWindow),ocrShortcuts.openWindow)],
            settings: add(L10n.text("settings"),#selector(showSettings)), quitTarget: self)
        statusMenu.delegate = self
        item.menu = statusMenu
    }

    internal func setupHotKeys() {
        hotKeyManager.onHotKey = { [weak self] in self?.handleSelectionHotKey() }
        screenshotHotKeyManager.onHotKey = { [weak self] in self?.startScreenshotTranslation() }
        replacementHotKeyManager.onHotKey = { [weak self] in self?.translateAndReplace() }
        inputHotKeyManager.onHotKey = { [weak self] in self?.handleInputHotKey() }
        regionCaptureHotKeyManager.onHotKey = { [weak self] in self?.captureScreenshot() }
        fullCaptureHotKeyManager.onHotKey = { [weak self] in self?.captureFullScreen() }
        previousCaptureHotKeyManager.onHotKey = { [weak self] in self?.capturePreviousArea() }
        pinVisibilityHotKeyManager.onHotKey = { ScreenshotAuxiliaryWindows.togglePins() }
        closeAllPinsHotKeyManager.onHotKey = {ScreenshotAuxiliaryWindows.closeAllPins()}
        clipboardPinHotKeyManager.onHotKey = { [weak self] in self?.pinFromClipboard() }
        imageEntryShortcuts.scroll.onHotKey = { [weak self] in self?.captureLongScreenshot() }
        imageEntryShortcuts.file.onHotKey = { [weak self] in self?.openLocalImage() }
        imageEntryShortcuts.clipboard.onHotKey = { [weak self] in self?.openClipboardImage() }
        ocrShortcuts.clipboard.onHotKey = { [weak self] in self?.clipboardOCR() }
        ocrShortcuts.file.onHotKey = { [weak self] in self?.openLocalImageOCR() }
        ocrShortcuts.openWindow.onHotKey = { [weak self] in self?.openOCRWindow() }
        for mode in OCRMode.allCases {ocrShortcuts.manager(mode).onHotKey={ [weak self] in self?.startOCR(mode)}}
        updateShortcutConflictNames()
        hotKeyManager.start()
        screenshotHotKeyManager.start()
        inputHotKeyManager.start()
        replacementHotKeyManager.start()
        regionCaptureHotKeyManager.start();fullCaptureHotKeyManager.start();previousCaptureHotKeyManager.start()
        pinVisibilityHotKeyManager.start(); clipboardPinHotKeyManager.start();closeAllPinsHotKeyManager.start()
        ocrShortcuts.managers.forEach{$0.start()}; imageEntryShortcuts.managers.forEach{$0.start()}
        installPanelKeyboardMonitor()
    }

    private var shortcutConflictNames: [(manager: HotKeyManager, name: LocalizedMessage)] {
        [
            (inputHotKeyManager, .key("translateTypedText")),
            (hotKeyManager, .key("translateSelection")),
            (screenshotHotKeyManager, .key("translateScreenshot")),
            (replacementHotKeyManager, .key("translateAndReplace")),
            (pinVisibilityHotKeyManager, .key("showOrHideAllPins")),
            (clipboardPinHotKeyManager, .key("pinFromClipboard")),
            (regionCaptureHotKeyManager, .key("screenshot")),
            (fullCaptureHotKeyManager, .key("captureFullScreen")),
            (previousCaptureHotKeyManager, .key("capture.previousArea")),
            (closePinHotKeyManager, .key("closePin")),
            (closeAllPinsHotKeyManager, .key("closeAllPins"))
        ] + OCRMode.allCases.map { (ocrShortcuts.manager($0), $0.titleMessage) } + [
            (ocrShortcuts.openWindow, .key("openOCRWindow")),
            (ocrShortcuts.clipboard, .key("clipboardOCR")),
            (ocrShortcuts.file, .key("localImageOCR")),
            (imageEntryShortcuts.scroll, .key("scrollingScreenshot")),
            (imageEntryShortcuts.file, .key("openLocalImage2")),
            (imageEntryShortcuts.clipboard, .key("openClipboardImage"))
        ]
    }

    private func updateShortcutConflictNames() {
        for (manager, _) in shortcutConflictNames {
            manager.conflictingAction = { [weak self, weak manager] candidate in
                self?.shortcutConflictNames.first {
                    let other = $0.manager
                    return other !== manager && other.isEnabled
                        && other.shortcut.keyCode == candidate.keyCode
                        && other.shortcut.carbonModifiers == candidate.carbonModifiers
                }?.name
            }
        }
    }

    @objc func interfaceLanguageDidChange(_ notification: Notification) {
        setupMenu()
        refreshStatusMenu()
        model.refreshServicePresentation()
        if settingsWindowController.isWindowLoaded {
            settingsWindowController.window?.title = L10n.text("sevenSettings")
        }
        if historyWindowController.isWindowLoaded {
            historyWindowController.window?.title = L10n.text("history.title")
        }
        onboardingWindowController?.refreshInterfaceLanguage()
        (panel?.contentViewController as? AppKitTranslationViewController)?.refreshInterfaceLanguage()
        refreshPanelTitlebarLanguage()
        frozenScreenshotCapture.refreshInterfaceLanguage()
        screenshotEditors.forEach { $0.refreshInterfaceLanguage() }
        scrollCapture?.refreshInterfaceLanguage()
        ocrWindowController?.refreshInterfaceLanguage()
        ScreenshotAuxiliaryWindows.refreshPinLanguage()
        inputReplacement.refreshInterfaceLanguage()
        PermissionGuide.shared.refreshInterfaceLanguage()
    }

    func setupMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.text("aboutSeven"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.text("settings"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(AppStatusMenu.quitItem(target: self))
        appItem.submenu = appMenu; main.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: L10n.text("edit"))
        edit.addItem(withTitle: L10n.text("undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L10n.text("cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L10n.text("copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L10n.text("paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L10n.text("selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; main.addItem(editItem)
        let windowItem = NSMenuItem(); let window = NSMenu(title: L10n.text("window"))
        window.addItem(withTitle: L10n.text("close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window; main.addItem(windowItem)
        NSApp.mainMenu = main
    }
    @objc func quitSeven() { NSApp.terminate(nil) }
    @objc func showSettings() {
        inputReplacement.cancel()
        if !model.pinned { panel?.dismiss() }
        settingsWindowController.show()
    }
    @objc func showHistory() {
        inputReplacement.cancel()
        if !model.pinned { panel?.dismiss() }
        historyWindowController.show()
    }

    /// 浮窗已在前台时再按一次即隐藏（同 Esc），否则在鼠标附近打开并聚焦输入框。
    private func handleInputHotKey() {
        if let panel, panel.isVisible, panel.isKeyWindow {
            model.hide()
        } else {
            showPanel()
        }
    }
    func menuWillOpen(_ menu: NSMenu) {
        for row in menu.items {
            if let manager=row.representedObject as? HotKeyManager {
                StatusMenuShortcut.apply(manager.isEnabled ? manager.shortcut:nil,to:row)
            }
        }
    }

    private func installPanelKeyboardMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            let textView = panel.firstResponder as? NSTextView
            guard let action = PanelKeyboardRouter.action(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                isEditingText: textView != nil,
                hasMarkedText: textView?.hasMarkedText() == true
            ) else { return event }

            switch action {
            case .translate, .retry:
                self.model.translate()
            case .insertNewline:
                guard let textView else { return event }
                textView.insertNewline(nil)
            case .togglePin:
                self.model.pinned.toggle()
            case .close:
                self.model.hide()
            }
            return nil
        }
    }

}
