import AppKit

@MainActor
final class AppKitTranslationInputView: LayerBackedView, NSTextViewDelegate, ThemeApplying {
    private var palette = ThemePalette.system
    private let model: TranslationModel
    private let scrollView = UserActivityScrollView()
    private let textView = PlaceholderTextView()
    private let toolsView = NSView()
    private let counterField = NSTextField(labelWithString: "")
    private let speechButton = SpeechToggleButton(label: L10n.text("readSourceTextAloud"))
    private let copyButton = AnimatedSymbolButton(symbol: "doc.on.doc", label: L10n.text("copySourceText"), weight: .medium, scale: .small)
    private let clearButton = SymbolButton(symbol: "xmark.circle.fill", label: L10n.text("clearSourceText"))
    private var editorHeightConstraint: NSLayoutConstraint!
    private var toolsHeightConstraint: NSLayoutConstraint!
    private var counterHeightConstraint: NSLayoutConstraint!
    private var maximumHeight: CGFloat
    private var appliesModelText = false
    private var synchronizedInput = ""

    func refreshInterfaceLanguage() {
        textView.placeholder = L10n.text("enterToTranslateOrEnterForA")
        copyButton.updateLocalizedLabel(L10n.text("copySourceText"))
        clearButton.updateLocalizedLabel(L10n.text("clearSourceText"))
        updateSpeechButton()
    }

    var layoutHeightConstraints: [NSLayoutConstraint] {
        [editorHeightConstraint, toolsHeightConstraint, counterHeightConstraint]
    }
    var renderedHeight: CGFloat { layoutHeightConstraints.reduce(0) { $0 + $1.constant } }

    var onPreferredHeightChange: ((CGFloat, Bool) -> Void)?
    var onClear: (() -> Void)?
    var onEditingLayoutChange: (() -> Void)?
    private(set) var preferredHeight: CGFloat = AutoGrowingTextHeightPolicy.minimum

    init(model: TranslationModel) {
        self.model = model
        self.maximumHeight = CGFloat(model.inputMaximumHeight)
        super.init(frame: .zero)
        cornerRadius = Design.Radius.block
        translatesAutoresizingMaskIntoConstraints = false

        OverlayScrollerPolicy.configure(scrollView)
        scrollView.installUserActivityIndicatorPolicy()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.focusRingType = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.delegate = self
        textView.onCompositionFinished = { [weak self] in self?.publishCommittedInput() }
        textView.onEditingLayoutChange = { [weak self] in self?.onEditingLayoutChange?() }
        textView.maximumVisibleHeight = maximumHeight
        textView.drawsBackground = false
        textView.focusRingType = .none
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.font = Design.Text.content.nsFont
        textView.textContainerInset = NSSize(width: Design.Space.blockInset, height: Design.Space.m)
        textView.textContainer?.lineFragmentPadding = 0
        textView.placeholder = L10n.text("enterToTranslateOrEnterForA")
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        textView.frame = NSRect(
            x: 0,
            y: 0,
            width: 500,
            height: AutoGrowingTextHeightPolicy.minimum
        )

        toolsView.translatesAutoresizingMaskIntoConstraints = false
        let leadingTools = NSStackView(views: [speechButton, copyButton])
        leadingTools.orientation = .horizontal
        leadingTools.spacing = Design.Space.xs
        leadingTools.translatesAutoresizingMaskIntoConstraints = false
        toolsView.addSubview(leadingTools)
        toolsView.addSubview(clearButton)
        for button in [speechButton, copyButton, clearButton] {
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Design.Icon.cardActionSize),
                button.heightAnchor.constraint(equalToConstant: Design.Icon.cardActionSize)
            ])
        }
        NSLayoutConstraint.activate([
            leadingTools.leadingAnchor.constraint(equalTo: toolsView.leadingAnchor, constant: Design.Space.iconButtonEdge),
            leadingTools.topAnchor.constraint(equalTo: toolsView.topAnchor, constant: Design.Space.xs),
            clearButton.trailingAnchor.constraint(equalTo: toolsView.trailingAnchor, constant: -Design.Space.iconButtonEdge),
            clearButton.topAnchor.constraint(equalTo: toolsView.topAnchor, constant: Design.Space.xs)
        ])

        counterField.translatesAutoresizingMaskIntoConstraints = false
        counterField.font = Design.Text.noteDigits.nsFont
        counterField.alignment = .right

        addSubview(scrollView)
        addSubview(toolsView)
        addSubview(counterField)
        editorHeightConstraint = scrollView.heightAnchor.constraint(
            equalToConstant: AutoGrowingTextHeightPolicy.minimum
        )
        toolsHeightConstraint = toolsView.heightAnchor.constraint(equalToConstant: 0)
        counterHeightConstraint = counterField.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            editorHeightConstraint,
            toolsView.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolsView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolsView.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            toolsHeightConstraint,
            counterField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Space.blockInset),
            counterField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Space.blockInset),
            counterField.topAnchor.constraint(equalTo: toolsView.bottomAnchor),
            counterHeightConstraint,
            counterField.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        speechButton.target = self
        speechButton.action = #selector(toggleSpeech)
        copyButton.target = self
        copyButton.action = #selector(copyInput)
        clearButton.target = self
        clearButton.action = #selector(clearInput)
        applyModel(animated: false)
        ThemeManager.shared.register(self)
    }

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        fillColor = palette.blockFill
        counterField.textColor = textView.string.count > 20_000 ? palette.error : palette.inkSecondary
        textView.textColor = palette.ink
        textView.placeholderColor = palette.placeholder
        textView.applyThemeSelection(palette)
        textView.needsDisplay = true
    }

    required init?(coder: NSCoder) { nil }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    func finishViewportLayout() {
        textView.revealDeferredInsertionPoint()
    }

    @discardableResult
    func applyModel(animated: Bool) -> Bool {
        maximumHeight = CGFloat(model.inputMaximumHeight)
        textView.maximumVisibleHeight = maximumHeight
        if textView.hasMarkedText(), model.input == synchronizedInput {
            // Keep IME-owned text, but continue measuring its provisional line layout.
            // Data synchronization and growing the visible viewport are independent.
            updateSpeechButton()
            return updateGeometry(animated: animated)
        }
        if textView.string != model.input {
            appliesModelText = true
            if textView.hasMarkedText() { textView.unmarkText() }
            textView.string = model.input
            appliesModelText = false
        }
        synchronizedInput = model.input
        updateSpeechButton()
        return updateGeometry(animated: animated)
    }

    @discardableResult
    func updateGeometry(animated: Bool) -> Bool {
        guard textView.bounds.width > 1 || bounds.width > 1 else { return false }
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        // NSTextView can resize itself during the first layout after a programmatic
        // replacement. Resolve the glyph range after that invalidation before measuring.
        _ = textView.layoutManager?.glyphRange(for: textView.textContainer!)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let usedHeight = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
        let measured = ceil(usedHeight + textView.textContainerInset.height * 2)
        let editorHeight = AutoGrowingTextHeightPolicy.clamped(measured, maximum: maximumHeight)
        let count = textView.string.count
        let toolsHeight: CGFloat = count > 0 ? 39 : 0
        let counterHeight: CGFloat = count >= 18_000 ? 22 : 0
        let nextPreferredHeight = editorHeight + toolsHeight + counterHeight
        let changed = abs(preferredHeight - nextPreferredHeight) > 0.5
        editorHeightConstraint.constant = editorHeight
        toolsHeightConstraint.constant = toolsHeight
        counterHeightConstraint.constant = counterHeight
        toolsView.isHidden = toolsHeight == 0
        counterField.isHidden = counterHeight == 0
        counterField.stringValue = "\(count) / 20,000"
        counterField.textColor = count > 20_000 ? palette.error : palette.inkSecondary
        preferredHeight = nextPreferredHeight
        let fullTextHeight = max(AutoGrowingTextHeightPolicy.minimum, measured)
        if !textView.hasMarkedText(), abs(textView.frame.height - fullTextHeight) > 0.5 {
            textView.setFrameSize(NSSize(width: textView.frame.width, height: fullTextHeight))
        }
        if changed { onPreferredHeightChange?(preferredHeight, animated) }
        return changed
    }

    func textDidChange(_ notification: Notification) {
        if textView.hasMarkedText() {
            onEditingLayoutChange?()
        } else {
            publishCommittedInput()
        }
    }

    private func publishCommittedInput() {
        guard !appliesModelText, !textView.hasMarkedText() else { return }
        let value = String(textView.string.prefix(20_001))
        if value != textView.string { textView.string = value }
        synchronizedInput = value
        model.updateInput(value)
    }

    override func layout() {
        super.layout()
        if textView.frame.width != scrollView.contentSize.width {
            textView.setFrameSize(NSSize(
                width: scrollView.contentSize.width,
                height: max(textView.frame.height, 1)
            ))
            _ = updateGeometry(animated: false)
        }
    }

    @objc private func toggleSpeech() {
        model.speech.toggle(
            content: .source,
            text: model.input,
            declaredLanguage: model.sourceLanguageForSpeech
        )
        updateSpeechButton()
    }

    @objc private func copyInput() {
        if model.copyInput() { copyButton.flashConfirmation() }
    }
    @objc private func clearInput() {
        if textView.hasMarkedText() { textView.unmarkText() }
        onClear?()
    }

    private func updateSpeechButton() {
        // Disable while online source-language detection is in flight to avoid speaking with a misdetected system language (e.g. Swahili detected as Indonesian).
        let pending = model.isSourceLanguagePending
        let language = model.sourceLanguageForSpeech
        speechButton.isEnabled = !pending && model.speech.canSpeak(text: model.input, declaredLanguage: language)
        speechButton.apply(
            model.speech.appearance(for: .source),
            symbol: model.speech.icon(for: .source),
            label: pending
                ? L10n.text("detectingLanguage")
                : model.speech.availabilityLabel(content: .source, text: model.input, declaredLanguage: language)
        )
    }
}

private final class PlaceholderTextView: NSTextView {
    var placeholderColor = ThemePalette.system.placeholder
    var placeholder = "" { didSet { needsDisplay = true } }
    var onCompositionFinished: (() -> Void)?
    var onEditingLayoutChange: (() -> Void)?
    var maximumVisibleHeight = AutoGrowingTextHeightPolicy.defaultMaximum

    private var deferredInsertionPoint = false

    private var canScrollInternally: Bool {
        frame.height > maximumVisibleHeight + 0.5
            && (enclosingScrollView?.contentSize.height ?? 0) >= maximumVisibleHeight - 0.5
    }

    func revealDeferredInsertionPoint() {
        guard deferredInsertionPoint else { return }
        if frame.height <= maximumVisibleHeight + 0.5 {
            deferredInsertionPoint = false
        } else if canScrollInternally {
            deferredInsertionPoint = false
            super.scrollRangeToVisible(selectedRange())
        }
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        // The native insertion-point scroll arrives before the viewport grows.
        // Wait until the visible editor reaches its cap, then reveal the caret once.
        guard canScrollInternally else {
            deferredInsertionPoint = frame.height > maximumVisibleHeight + 0.5
            return
        }
        super.scrollRangeToVisible(range)
    }

    override func scrollToVisible(_ rect: NSRect) -> Bool {
        guard canScrollInternally else {
            deferredInsertionPoint = frame.height > maximumVisibleHeight + 0.5
            return false
        }
        return super.scrollToVisible(rect)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let wasComposing = hasMarkedText()
        super.insertText(insertString, replacementRange: replacementRange)
        if wasComposing, !hasMarkedText() { onCompositionFinished?() }
    }

    override func unmarkText() {
        let wasComposing = hasMarkedText()
        super.unmarkText()
        if wasComposing { onCompositionFinished?() }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let wasComposing = hasMarkedText()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onEditingLayoutChange?()
        if wasComposing, !hasMarkedText() { onCompositionFinished?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? Design.Text.content.nsFont,
            .foregroundColor: placeholderColor
        ]
        NSString(string: placeholder).draw(
            at: NSPoint(
                x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                y: textContainerOrigin.y
            ),
            withAttributes: attributes
        )
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
