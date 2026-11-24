import AppKit

extension AppDelegate {
    var canOpenImageEntry: Bool {
        !frozenScreenshotCapture.isCapturing && scrollCapture == nil && !screenshotEditors.contains { $0.window?.isVisible == true }
    }
    @objc func openLocalImage() { chooseImage(forOCR: false) }
    @objc func openLocalImageOCR() { chooseImage(forOCR: true) }
    private func chooseImage(forOCR: Bool) {
        guard canOpenImageEntry else { return }
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = ImageImport.supportedTypes
        chooser.canChooseDirectories = false; chooser.allowsMultipleSelection = false
        chooser.message = forOCR ? L10n.text("chooseAnImageForTextRecognition") : L10n.text("chooseAnImageToEdit")
        NSApp.activate(ignoringOtherApps: true)
        guard chooser.runModal() == .OK, let url = chooser.url else { return }
        openImageFiles([url], forOCR: forOCR)
    }
    @objc func openClipboardImage() { openClipboard(forOCR: false) }
    @objc func clipboardOCR() { openClipboard(forOCR: true) }
    private func openClipboard(forOCR: Bool) {
        guard canOpenImageEntry else { return }
        do { presentImportedImage(try ImageImport.clipboard(.general), forOCR: forOCR) }
        catch { showImageImportError(error as? ImageImportError ?? .unreadable) }
    }
    func openImageFiles(_ urls: [URL], forOCR: Bool = true) {
        guard canOpenImageEntry else { return }
        guard urls.count == 1, let url = urls.first else { showImageImportError(.multipleFiles); return }
        do { presentImportedImage(try ImageImport.file(url), forOCR: forOCR) }
        catch { showImageImportError(error as? ImageImportError ?? .unreadable) }
    }
    private func presentImportedImage(_ image: NSImage, forOCR: Bool) {
        inputReplacement.cancel(); cancelSelectionWork(); cancelScreenshotWork()
        if forOCR { showScreenshotOCR(image); return }
        ocrWindowController?.close()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let context = ScreenshotCenteredEditorContext(screenFrame: screen.frame, background: nil)
        let editor = ScreenshotEditorWindowController(image: image, context: .centered(context))
        configureScreenshotEditor(editor); presentScreenshotEditor(editor)
    }
    private func showImageImportError(_ error: ImageImportError) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = L10n.text("couldNotOpenImage"); alert.informativeText = error.localizedDescription
        alert.runModal()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard imageEntriesReady else { pendingImageURLs.append(contentsOf: urls); return }
        openImageFiles(urls)
    }
}
