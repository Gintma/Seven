import AppKit
import UniformTypeIdentifiers

@MainActor final class ScreenshotOCRWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSMenuDelegate, NSSplitViewDelegate, ThemeApplying {
    var onOpenImage: (() -> Void)?
    var onOpenFiles: (([URL]) -> Void)?
    var onTranslate: ((String) -> Void)?
    private(set) var isPinned = false
    let textView = OCRResultTextView()
    private let progressLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var progressKey: String? {
        didSet { progressLabel.stringValue = progressKey.map(L10n.text) ?? "" }
    }
    private let languageButton = LanguageMenuButton(accessibilityLabel: L10n.text("ocrLanguage"))
    private let copyButton = AnimatedSymbolButton(symbol: "doc.on.doc", label: L10n.text("copyText"), size: Design.Icon.action)
    private let translateButton = SymbolButton(symbol: "translate", label: L10n.text("translate"), size: Design.Icon.action)
    private let exportButton = SymbolButton(symbol: "square.and.arrow.down", label: L10n.text("exportText"), size: Design.Icon.action)
    private let pinButton = SymbolButton(symbol: "pin", label: L10n.text("pinWindow2"), size: Design.Icon.action)
    private let originalButton = SymbolButton(symbol: "photo", label: L10n.text("originalImage"), size: Design.Icon.action)
    private let openButton = SymbolButton(symbol: "folder", label: L10n.text("openImage"), size: Design.Icon.action)
    private let layoutButton = SymbolButton(symbol: "text.alignleft", label: L10n.text("layout"), size: Design.Icon.action)
    let imagePreview: OCRImagePreview?
    private let split = OCRResultSplitView()
    private let textPanel = LayerBackedView(frame: .zero)
    private let imagePanel = LayerBackedView(frame: .zero)
    private let statusRow = NSStackView()
    private(set) var showsOriginal: Bool
    private var restoringGeometry = false
    private var hasShown = false
    private var image: NSImage?
    private var compressedImage: OCRCompressedImage?
    private let originalImageSize: NSSize?
    private var compressionTask: Task<Void, Never>?
    private var compressionUnavailable = false
    private let recognizer: @Sendable (String) -> any TextRecognizing
    private let defaults: UserDefaults?
    private let preferredLanguageCodes: [String]
    private let supportedLanguages: [String]
    private let copy: (String) -> Bool
    private var language: String
    private var layoutSource: String?
    private var layoutLines: [OCRTextLine] = []
    private var replacingText = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private(set) var isRecognizing = false
    private(set) var layoutMode: OCRResultLayout
    private var menuTracking = false

    init(image: NSImage? = nil, result: RecognizedOCRText? = nil,
         recognizer: (any TextRecognizing)? = nil,
         recognizerFactory: (@Sendable (String) -> any TextRecognizing)? = nil,
         defaults: UserDefaults? = .standard, commonLanguages: [String] = [],
         supportedLanguages: [String]? = nil, copy: ((String) -> Bool)? = nil) {
        self.image = image; self.originalImageSize = image?.size
        self.layoutSource = result?.text; self.layoutLines = result?.lines ?? []; self.defaults = defaults
        self.imagePreview = image.map { OCRImagePreview(image: $0) }
        self.showsOriginal = image != nil && (defaults?.bool(forKey: OCRWindowPreferences.showOriginal) ?? false)
        self.layoutMode = defaults?.string(forKey: OCRResultLayout.preferenceKey).flatMap(OCRResultLayout.init(rawValue:)) ?? .smart
        self.recognizer = recognizerFactory ?? { language in recognizer ?? ScreenshotImageTextRecognizer(language: language) }
        self.preferredLanguageCodes = commonLanguages
        self.supportedLanguages = supportedLanguages ?? OCRRecognitionLanguages.supported()
        let saved = defaults?.string(forKey: OCRRecognitionLanguages.preferenceKey) ?? LanguageCatalog.automatic
        language = self.supportedLanguages.contains(saved) ? saved : LanguageCatalog.automatic
        self.copy = copy ?? { text in NSPasteboard.general.clearContents(); return NSPasteboard.general.setString(text, forType: .string) }
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: showsOriginal ? Design.OCR.comparisonSize : Design.OCR.windowSize),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = L10n.text("recognizeText"); window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        // NSPanel 默认 true 会绕过点击外部关闭逻辑，导致钉住后切到别的应用仍消失。
        window.hidesOnDeactivate = false
        window.minSize = Design.OCR.minimumSize
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        imagePreview?.setPresentationActive(false)
        imagePreview?.onMenuTrackingChange = { [weak self] tracking in self?.menuTracking = tracking }
        imagePreview?.recognitionLanguage = language
        buildContent(window)
        ThemeManager.shared.register(self)
        window.delegate = self; restoreGeometry()
        if let result { textView.string = layoutMode.apply(to: result.text, lines: result.lines) }
        else if image != nil { recognize() }
        updateActions()
    }
    required init?(coder: NSCoder) { nil }

    func applyTheme(_ palette: ThemePalette) {
        window?.backgroundColor = palette.surface
        split.applyTheme(palette)
        textView.textColor = palette.ink
        textView.applyThemeSelection(palette)
        progressLabel.textColor = palette.inkSecondary
        textPanel.fillColor = palette.blockFill
        imagePanel.fillColor = palette.blockFill
    }

    private func buildContent(_ window: NSWindow) {
        let scroll = NSScrollView(); scroll.documentView = textView; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false; OverlayScrollerPolicy.configure(scroll)
        textView.font = Design.Text.content.nsFont
        textView.drawsBackground = false; textView.isRichText = false; textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: Design.Space.l, height: Design.Space.l)
        textView.autoresizingMask = [.width]; textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true; textView.delegate = self
        textView.setAccessibilityLabel(L10n.text("recognizedTextEditable"))
        textView.onOpenFiles = { [weak self] urls in self?.onOpenFiles?(urls) }
        languageButton.menuProvider = { [weak self] in self?.languageMenu() ?? NSMenu() }
        languageButton.horizontalContentInset = Design.OCR.languageHorizontalInset
        updateLanguageLabel(); languageButton.isEnabled = image != nil
        layoutButton.target = self; layoutButton.action = #selector(showLayoutMenu)
        updateLayoutButton()
        pinButton.target = self; pinButton.action = #selector(togglePin)
        originalButton.target = self; originalButton.action = #selector(toggleOriginal); originalButton.isEnabled = image != nil
        updateOriginalButton()
        openButton.target = self; openButton.action = #selector(openImage)
        let top = NSStackView(views: [NSView(), openButton, originalButton, pinButton]); top.spacing = Design.Space.s
        translateButton.target = self; translateButton.action = #selector(translateText)
        exportButton.target = self; exportButton.action = #selector(exportText)
        copyButton.target = self; copyButton.action = #selector(copyText)
        for button in [openButton, layoutButton, copyButton, pinButton, originalButton, translateButton, exportButton] {
            button.widthAnchor.constraint(equalToConstant: Design.OCR.actionSize).isActive = true
            button.heightAnchor.constraint(equalToConstant: Design.OCR.actionSize).isActive = true
        }
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false; progress.isHidden = true
        progressLabel.font = Design.Text.note.nsFont
        progressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusRow.addArrangedSubview(progress); statusRow.addArrangedSubview(progressLabel)
        statusRow.spacing = Design.Space.s; statusRow.isHidden = true
        let bottom = NSStackView(views: [layoutButton, languageButton, NSView(), copyButton, translateButton, exportButton])
        bottom.spacing = Design.Space.s
        let textContent = NSStackView(views: [scroll, statusRow, bottom]); textContent.orientation = .vertical
        textContent.alignment = .centerX; textContent.spacing = Design.Space.s; textContent.translatesAutoresizingMaskIntoConstraints = false
        textPanel.cornerRadius = Design.Radius.block
        textPanel.addSubview(textContent)
        NSLayoutConstraint.activate([
            textContent.leadingAnchor.constraint(equalTo: textPanel.leadingAnchor), textContent.trailingAnchor.constraint(equalTo: textPanel.trailingAnchor),
            textContent.topAnchor.constraint(equalTo: textPanel.topAnchor), textContent.bottomAnchor.constraint(equalTo: textPanel.bottomAnchor, constant: -Design.OCR.bottomActionsInset),
            scroll.widthAnchor.constraint(equalTo: textContent.widthAnchor),
            bottom.leadingAnchor.constraint(equalTo: textPanel.leadingAnchor, constant: Design.Space.l),
            bottom.trailingAnchor.constraint(equalTo: textPanel.trailingAnchor, constant: -Design.Space.l),
            statusRow.leadingAnchor.constraint(equalTo: bottom.leadingAnchor), statusRow.trailingAnchor.constraint(equalTo: bottom.trailingAnchor),
            languageButton.heightAnchor.constraint(equalToConstant: Design.OCR.languageHeight)
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        split.isVertical = true; split.dividerStyle = .thin; split.delegate = self
        if let imagePreview {
            imagePanel.cornerRadius = Design.Radius.block
            imagePreview.translatesAutoresizingMaskIntoConstraints = false
            imagePanel.addSubview(imagePreview)
            NSLayoutConstraint.activate([
                imagePreview.leadingAnchor.constraint(equalTo: imagePanel.leadingAnchor, constant: Design.Space.l),
                imagePreview.trailingAnchor.constraint(equalTo: imagePanel.trailingAnchor, constant: -Design.Space.l),
                imagePreview.topAnchor.constraint(equalTo: imagePanel.topAnchor, constant: Design.Space.l),
                imagePreview.bottomAnchor.constraint(equalTo: imagePanel.bottomAnchor, constant: -Design.Space.l)
            ])
        }
        if showsOriginal { split.addSubview(imagePanel) }
        split.addSubview(textPanel)
        let root = NSStackView(views: [top, split]); root.orientation = .vertical
        root.alignment = .leading; root.spacing = Design.OCR.topPanelGap; root.translatesAutoresizingMaskIntoConstraints = false
        let host = OCRImageDropView(); host.onOpenFiles = { [weak self] urls in self?.onOpenFiles?(urls) }
        host.addSubview(root); window.contentView = host
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Design.Space.l), root.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Design.Space.l),
            root.topAnchor.constraint(equalTo: host.topAnchor, constant: Design.OCR.topPanelGap), root.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Design.Space.l),
            top.widthAnchor.constraint(equalTo: root.widthAnchor), top.heightAnchor.constraint(equalToConstant: Design.OCR.topBarHeight), split.widthAnchor.constraint(equalTo: root.widthAnchor),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: Design.OCR.minimumTextHeight)
        ])
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
    override func showWindow(_ sender: Any?) {
        cancelImageCompression()
        if showsOriginal { restoreOriginalIfNeeded() }
        imagePreview?.setPresentationActive(true)
        super.showWindow(sender)
        hasShown = true
        window?.makeFirstResponder(textView)
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.window === self?.window { self?.imagePreview?.clearSelectionIfOutside(event.locationInWindow) }
                self?.dismissForOutsideClick(event.window)
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissForOutsideClick(nil) }
        }
    }
    func dismissForOutsideClick(_ clickedWindow: NSWindow?) {
        guard !isPinned, !menuTracking, window?.isVisible == true, window?.attachedSheet == nil,
              NSApp.modalWindow == nil else { return }
        if let clickedWindow, clickedWindow === window || clickedWindow.parent === window { return }
        // 原生菜单跟踪期间不收起，也不把本窗口按钮产生的事件当作外部点击。
        close()
    }
    func menuWillOpen(_ menu: NSMenu) { menuTracking = true }
    func menuDidClose(_ menu: NSMenu) { menuTracking = false }
    /// 新图片会替换结果窗口，但钉住是窗口会话选择，不能随着识别内容被清空。
    func inheritPinState(from previous: ScreenshotOCRWindowController?) {
        if let previous, previous !== self, previous.isPinned != isPinned { togglePin() }
    }
    @objc func togglePin() {
        isPinned.toggle(); window?.level = isPinned ? .floating : .normal
        pinButton.setSymbol(isPinned ? "pin.fill" : "pin"); pinButton.setThemeTint(isPinned ? .accent : .inkSecondary)
        pinButton.setAccessibilityValue(isPinned ? L10n.text("pinned") : L10n.text("unpinned"))
    }
    @objc func toggleOriginal() {
        guard imagePreview != nil else { return }
        saveGeometry()
        showsOriginal.toggle(); defaults?.set(showsOriginal, forKey: OCRWindowPreferences.showOriginal)
        restoringGeometry = true
        if showsOriginal {
            restoreOriginalIfNeeded()
            split.addSubview(imagePanel, positioned: .below, relativeTo: textPanel)
        }
        else { imagePanel.removeFromSuperview() }
        restoreSplitPosition()
        restoringGeometry = false
        updateOriginalButton(); saveGeometry()
    }
    private func updateOriginalButton() {
        originalButton.setThemeTint(showsOriginal ? .accent : .inkSecondary)
        originalButton.setAccessibilityValue(showsOriginal ? L10n.text("showOriginalImage") : L10n.text("hideOriginalImage"))
    }
    private func restoreGeometry() {
        guard let window else { return }
        restoringGeometry = true
        defer { restoringGeometry = false }
        // 旧版分开记单栏/双栏；只在首次恢复时读取旧值，切换不再套用另一个外框。
        let legacyKey = showsOriginal ? OCRWindowPreferences.comparisonFrame : OCRWindowPreferences.textFrame
        if let saved = defaults?.string(forKey: OCRWindowPreferences.frame) ?? defaults?.string(forKey: legacyKey) {
            window.setFrame(NSRectFromString(saved), display: false)
        } else {
            window.setContentSize(showsOriginal ? Design.OCR.comparisonSize : Design.OCR.windowSize)
            window.center()
        }
        if let screen = window.screen ?? NSScreen.main {
            var frame = window.frame
            frame.size.width = min(screen.visibleFrame.width, max(window.minSize.width, frame.width))
            frame.size.height = min(screen.visibleFrame.height, max(window.minSize.height, frame.height))
            frame.origin.x = min(max(frame.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, screen.visibleFrame.minY), screen.visibleFrame.maxY - frame.height)
            window.setFrame(frame, display: false)
        }
        restoreSplitPosition()
    }
    private func restoreSplitPosition() {
        window?.contentView?.layoutSubtreeIfNeeded(); split.adjustSubviews()
        if showsOriginal {
            let saved = defaults?.object(forKey: OCRWindowPreferences.splitRatio) as? Double ?? 0.5
            let position = (split.bounds.width - split.dividerThickness) * saved
            split.setPosition(min(max(Design.OCR.minimumPanelWidth, position), split.bounds.width - split.dividerThickness - Design.OCR.minimumPanelWidth), ofDividerAt: 0)
        }
        window?.contentView?.layoutSubtreeIfNeeded()
    }
    private func saveGeometry() {
        guard hasShown, !restoringGeometry, let window else { return }
        defaults?.set(NSStringFromRect(window.frame), forKey: OCRWindowPreferences.frame)
    }
    func windowDidResize(_ notification: Notification) { saveGeometry() }
    func windowDidMove(_ notification: Notification) { saveGeometry() }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { Design.OCR.minimumPanelWidth }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { splitView.bounds.width - splitView.dividerThickness - Design.OCR.minimumPanelWidth }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard showsOriginal, hasShown, !restoringGeometry, split.bounds.width > split.dividerThickness else { return }
        defaults?.set(imagePanel.frame.width / (split.bounds.width - split.dividerThickness), forKey: OCRWindowPreferences.splitRatio)
    }
    func languageMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self
        func item(_ title: String, code: String) -> NSMenuItem {
            let item = OCRMenuItem(title: title) { [weak self] in self?.selectLanguage(code) }
            item.state = language == code ? .on : .off; return item
        }
        menu.addItem(item(L10n.text("detectAutomatically2"), code: LanguageCatalog.automatic)); menu.addItem(.separator())
        let ordered = OCRRecognitionLanguages.ordered(supportedLanguages, common: preferredLanguageCodes)
        for code in ordered.common { menu.addItem(item(OCRRecognitionLanguages.name(code), code: code)) }
        let more = NSMenuItem(title: L10n.text("moreLanguages"), action: nil, keyEquivalent: ""), submenu = NSMenu()
        for code in ordered.other { submenu.addItem(item(OCRRecognitionLanguages.name(code), code: code)) }
        if !ordered.other.isEmpty {
            more.submenu = submenu; more.state = ordered.other.contains(language) ? .on : .off; menu.addItem(more)
        }
        return menu
    }
    func selectLanguage(_ value: String) {
        guard originalImageSize != nil, value == LanguageCatalog.automatic || supportedLanguages.contains(value) else { return }
        language = value; defaults?.set(value, forKey: OCRRecognitionLanguages.preferenceKey)
        imagePreview?.recognitionLanguage = value
        updateLanguageLabel(); recognize()
    }
    func refreshInterfaceLanguage() {
        window?.title = L10n.text("recognizeText")
        textView.setAccessibilityLabel(L10n.text("recognizedTextEditable"))
        languageButton.setAccessibilityLabel(L10n.text("ocrLanguage"))
        openButton.updateLocalizedLabel(L10n.text("openImage"))
        copyButton.updateLocalizedLabel(L10n.text("copyText"))
        translateButton.updateLocalizedLabel(L10n.text("translate"))
        exportButton.updateLocalizedLabel(L10n.text("exportText"))
        pinButton.updateLocalizedLabel(L10n.text("pinWindow2"))
        pinButton.setAccessibilityValue(isPinned ? L10n.text("pinned") : L10n.text("unpinned"))
        originalButton.updateLocalizedLabel(L10n.text("originalImage"))
        layoutButton.setAccessibilityLabel(L10n.text("layout"))
        imagePreview?.refreshInterfaceLanguage()
        progressLabel.stringValue = progressKey.map(L10n.text) ?? ""
        updateLanguageLabel()
        updateLayoutButton()
        updateOriginalButton()
        updateActions()
    }

    private func updateLanguageLabel() {
        languageButton.apply(.init(name: language == LanguageCatalog.automatic ? L10n.text("detectAutomatically2") : OCRRecognitionLanguages.name(language), note: nil), help: L10n.text("changingTheRecognitionLanguageRunsOCRAgain"))
    }
    private func recognize() {
        cancelImageCompression()
        restoreOriginalIfNeeded()
        task?.cancel(); generation = UUID()
        guard let image, let cg = ScreenshotSaving.cgImage(image) else { return }
        let token = generation, worker = recognizer(language)
        isRecognizing = true; progress.isHidden = false; progress.startAnimation(nil)
        progressKey = "recognizingText"; updateActions()
        task = Task { [weak self] in
            do {
                let result = try await worker.recognizeText(in: cg)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.layoutSource = result.text
                self.layoutLines = result.lines
                self.replaceText(self.layoutMode.apply(to: result.text, lines: result.lines), action: L10n.text("recognizeAgain"))
                self.progressKey = nil; self.finishRecognition()
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.progressKey = "ocr.recognitionFailed"
                self.finishRecognition()
            }
        }
    }
    private func finishRecognition() {
        task = nil; isRecognizing = false; progress.stopAnimation(nil); progress.isHidden = true; updateActions()
        if hasShown, window?.isVisible == false { scheduleImageCompression() }
    }
    func applyLayout(_ mode: OCRResultLayout) {
        layoutMode = mode; defaults?.set(mode.rawValue, forKey: OCRResultLayout.preferenceKey)
        updateLayoutButton()
        let source = layoutSource ?? textView.string
        layoutSource = source
        replaceText(mode.apply(to: source, lines: layoutLines), action: mode.title)
    }
    private func updateLayoutButton() {
        layoutButton.toolTip = L10n.format("layout2", String(describing: layoutMode.title))
        layoutButton.setAccessibilityValue(layoutMode.title)
    }
    func layoutMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self
        for mode in OCRResultLayout.allCases {
            let item = OCRMenuItem(title: mode.title) { [weak self] in self?.applyLayout(mode) }
            item.state = mode == layoutMode ? .on : .off; menu.addItem(item)
        }
        return menu
    }
    @objc private func showLayoutMenu() {
        layoutMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: -Design.Space.xs), in: layoutButton)
    }
    func replaceText(_ text: String, action: String) {
        guard text != textView.string else { return }
        replacingText = true
        defer { replacingText = false }
        textView.breakUndoCoalescing()
        textView.insertText(text, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
        textView.breakUndoCoalescing(); textView.undoManager?.setActionName(action); updateActions()
    }
    @objc private func openImage() { onOpenImage?() }
    @objc func copyText() {
        if copy(textView.string) { copyButton.flashConfirmation() }
    }
    @objc private func translateText() {
        guard !textView.string.isEmpty else { return }
        onTranslate?(textView.string)
        if !isPinned { close() }
    }
    @objc private func exportText() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Seven_OCR.txt"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try Data(self.textView.string.utf8).write(to: url, options: .atomic) }
            catch { self.progressKey = "exportFailedCheckTheDestination"; self.updateActions() }
        }
    }
    func textDidChange(_ notification: Notification) {
        if !replacingText { layoutSource = nil; layoutLines = [] }
        updateActions()
    }
    private func updateActions() {
        copyButton.isEnabled = !textView.string.isEmpty; translateButton.isEnabled = !textView.string.isEmpty
        exportButton.isEnabled = !textView.string.isEmpty; layoutButton.isEnabled = !isRecognizing
        statusRow.isHidden = progressLabel.stringValue.isEmpty
    }
    /// 用户关闭只是收起；当前原图、编辑文字、撤销历史和钉住状态留在本次应用会话中。
    override func close() {
        saveGeometry(); window?.orderOut(nil); stopOutsideMonitoring()
        imagePreview?.setPresentationActive(false)
        scheduleImageCompression()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
    /// 新识别结果替换旧窗口、或应用退出时才真正释放任务与窗口。
    func dispose() {
        cancelImageCompression()
        imagePreview?.replaceDisplayedImage(nil)
        image = nil
        compressedImage = nil
        cancelRecognition(); stopOutsideMonitoring(); super.close()
    }
    private func cancelRecognition() { generation = UUID(); task?.cancel(); task = nil }
    private func stopOutsideMonitoring() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
    }
    func windowWillClose(_ notification: Notification) {
        saveGeometry(); cancelRecognition(); stopOutsideMonitoring()
        cancelImageCompression()
    }

    private func scheduleImageCompression() {
        guard compressionTask == nil, !compressionUnavailable, !isRecognizing,
              let image, image.representations.count == 1, imagePreview?.hasActiveTextSelection != true else { return }
        compressionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            guard let self, self.window?.isVisible == false, let image = self.image,
                  let raster = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self?.compressionTask = nil
                return
            }
            let worker = Task.detached(priority: .utility) { autoreleasepool { OCRCompressedImage(raster) } }
            let compressed = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            // A previous close may still be finishing after the window was reopened and closed again.
            guard !Task.isCancelled else { return }
            self.compressionTask = nil
            guard let compressed else {
                self.compressionUnavailable = true
                return
            }
            self.compressedImage = compressed
            self.imagePreview?.replaceDisplayedImage(nil)
            self.image = nil
        }
    }

    private func cancelImageCompression() {
        compressionTask?.cancel()
        compressionTask = nil
    }

    private func restoreOriginalIfNeeded() {
        guard let compressedImage, let originalImageSize,
              let raster = autoreleasepool(invoking: { compressedImage.makeImage() }) else { return }
        let restored = NSImage(cgImage: raster, size: originalImageSize)
        image = restored
        imagePreview?.replaceDisplayedImage(restored)
        self.compressedImage = nil
    }
}

private final class OCRMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler; super.init(title: title, action: #selector(choose), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func choose() { handler() }
}

/// 无常驻应用菜单栏时也支持原生文字编辑快捷键，不截获输入法组合按键。
final class OCRResultTextView: NSTextView {
    var onOpenFiles: (([URL]) -> Void)?
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if onOpenFiles != nil, !OCRImageDropView.fileURLs(from: sender.draggingPasteboard).isEmpty { return .copy }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if onOpenFiles != nil, !OCRImageDropView.fileURLs(from: sender.draggingPasteboard).isEmpty { return .copy }
        return super.draggingUpdated(sender)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if onOpenFiles != nil, !OCRImageDropView.fileURLs(from: sender.draggingPasteboard).isEmpty { return true }
        return super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = OCRImageDropView.fileURLs(from: sender.draggingPasteboard)
        if let onOpenFiles, !urls.isEmpty { onOpenFiles(urls); return true }
        return super.performDragOperation(sender)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command || modifiers == [.command, .shift] {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z": if modifiers.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
            case "c": copy(nil)
            case "x": cut(nil)
            case "v": paste(nil)
            case "a": selectAll(nil)
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 仅记窗口几何、视图选择与分栏比例，不保存图片或识别正文。
enum OCRWindowPreferences {
    static let showOriginal = "ocr.showOriginal.v1"
    static let frame = "ocr.windowFrame.v1"
    // 只用于读取旧版本的窗口几何。
    static let textFrame = "ocr.windowFrame.text.v1"
    static let comparisonFrame = "ocr.windowFrame.comparison.v1"
    static let splitRatio = "ocr.splitRatio.v1"
}
