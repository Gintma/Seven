import AppKit

extension AppDelegate {
    func configureScreenshotEditor(_ editor: ScreenshotEditorWindowController, captureRect: CGRect? = nil) {
        let screen = frozenScreenshotCapture.lastCaptureScreenFrame
        editor.onExportSuccess = { [weak self, weak editor] in
            guard let self, let finalRect = editor?.captureRect ?? captureRect, let screen else { return }
            self.frozenScreenshotCapture.rememberArea(finalRect, on: screen)
        }
        editor.onPin = { [weak self] image in self?.showScreenshotPin(image) }
        editor.onOCR = { [weak self] image in self?.showScreenshotOCR(image) }
        if (editor.captureRect ?? captureRect) != nil, frozenScreenshotCapture.lastSelectionContext?.isWindowComposition != true {
            editor.onScroll = { [weak editor, weak self] _ in
                guard let self, let currentRect = editor?.captureRect ?? captureRect else { return }
                editor?.close(); self.startScrollCapture(in: currentRect)
            }
        }

    }
    func startScrollCapture(in rect: CGRect) {
        let activeID = UUID()
        let controller = ScreenshotScrollWindowController(rect: rect, sessionID: activeID) { [weak self] image in
            guard let self, let capture = self.scrollCapture, capture.sessionID == activeID else { return }
            let screen = capture.backgroundFrame?.screenFrame ?? NSScreen.screens.first(where: { $0.frame.intersects(rect) })?.frame ?? rect
            let context = ScreenshotCenteredEditorContext(screenFrame: screen, background: capture.backgroundFrame?.image)
            let result = ScreenshotEditorWindowController(image: image, context: .centered(context))
            self.configureScreenshotEditor(result)
            let action = capture.outputAction
            self.presentScreenshotEditor(result); result.performScrollAction(action)
        }
        scrollCapture = controller
        ScreenshotAuxiliaryWindows.show(controller, activateApplication: false) { [weak self] in
            if self?.scrollCapture?.sessionID == activeID { self?.scrollCapture = nil }
        }
    }
    func presentScreenshotEditor(_ editor: ScreenshotEditorWindowController) {
        let identity = ObjectIdentifier(editor)
        screenshotEditors.append(editor)
        ScreenshotAuxiliaryWindows.show(editor, activateApplication: false) { [weak self] in
            self?.screenshotEditors.removeAll { ObjectIdentifier($0) == identity }
        }
    }
    func showScreenshotOCR(_ image: NSImage, level: NSWindow.Level? = nil) {
        let controller = ScreenshotOCRWindowController(image: image, commonLanguages: model.commonLanguages)
        presentOCR(controller,level:level)
    }
    func showRecognizedOCR(_ result:RecognizedOCRText, image: NSImage) {
        presentOCR(ScreenshotOCRWindowController(image: image, result: result, commonLanguages: model.commonLanguages))
    }
    @objc func openOCRWindow() {
        let controller = ocrWindowController ?? ScreenshotOCRWindowController(commonLanguages: model.commonLanguages)
        presentOCR(controller)
    }
    private func presentOCR(_ controller:ScreenshotOCRWindowController,level:NSWindow.Level? = nil) {
        if ocrWindowController !== controller {
            controller.inheritPinState(from: ocrWindowController)
            ocrWindowController?.dispose()
        }
        ocrWindowController = controller
        if let level {controller.window?.level=level}
        controller.onOpenImage = { [weak self] in self?.openLocalImageOCR() }
        controller.onOpenFiles = { [weak self] urls in self?.openImageFiles(urls) }
        controller.onTranslate = { [weak self] text in
            guard let self else { return }
            self.inputReplacement.cancel()
            self.model.prepareSelectedText(text)
            self.presentPanel(near: NSEvent.mouseLocation)
            self.model.translate()
        }
        ScreenshotAuxiliaryWindows.show(controller)
    }
    @objc func pinFromClipboard() {
        do { showScreenshotPin(try ScreenshotClipboardPin.image(from: .general)) }
        catch {
            let alert = NSAlert(); alert.messageText = L10n.text("couldNotPinFromClipboard"); alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
    private func showScreenshotPin(_ image: NSImage) {
        let controller = ScreenshotPinWindowController(image:image,closeShortcut:closePinHotKeyManager,closeAllShortcut:closeAllPinsHotKeyManager)
        controller.onAnnotate = { [weak self, weak controller] image in
            guard let self, let editor = controller?.makeEditor() else { return }
            self.configureScreenshotEditor(editor)
            editor.onOCR={ [weak self,weak controller] image in self?.showScreenshotOCR(image,level:controller?.window?.level) }
            self.presentScreenshotEditor(editor)
            editor.window?.makeKey() // 仅让非激活编辑面板接收输入，不提升设置等普通窗口。
        }
        controller.onOCR = { [weak self, weak controller] image in self?.showScreenshotOCR(image, level: controller?.window?.level) }
        controller.onCloseAll = { ScreenshotAuxiliaryWindows.closeAllPins() }
        ScreenshotAuxiliaryWindows.show(controller, activateApplication: false)
    }

}

/// 每个辅助窗口由此持有到关闭；通知只移除对应窗口，不读取或保存截图历史。
@MainActor enum ScreenshotAuxiliaryWindows {
    private struct Entry {
        let controller: NSWindowController
        let observer: NSObjectProtocol
        let onClose: (() -> Void)?
    }
    private static var entries: [ObjectIdentifier: Entry] = [:]
    private static var pins: [ScreenshotPinWindowController] {
        entries.values.compactMap { $0.controller as? ScreenshotPinWindowController }.filter { !$0.isClosed }
    }
    static func refreshPinLanguage() {
        pins.forEach { $0.refreshInterfaceLanguage() }
    }

    static func closeAllPins() { for controller in pins { controller.close() } }
    static func togglePins() {
        let current = pins
        let hide = current.contains { $0.window?.isVisible == true }
        for controller in current {
            controller.setVisible(!hide)
        }
    }
    static func show(_ controller: NSWindowController, activateApplication: Bool = true, onClose: (() -> Void)? = nil) {
        guard let window = controller.window else { return }
        let id = ObjectIdentifier(window)
        if let old = entries.removeValue(forKey: id) { NotificationCenter.default.removeObserver(old.observer) }
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            // 保留controller直到willClose的delegate与其他观察者都完成清理。
            DispatchQueue.main.async {
                if let entry = entries.removeValue(forKey: id) {
                    NotificationCenter.default.removeObserver(entry.observer)
                    entry.onClose?()
                }
            }
        }
        entries[id] = Entry(controller: controller, observer: observer, onClose: onClose)
        controller.showWindow(nil)
        if activateApplication {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // 截图覆盖层/采集面板不提升设置、历史等普通窗口，保持原应用的窗口顺序。
            window.orderFrontRegardless()
        }
    }
}
