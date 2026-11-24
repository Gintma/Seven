import AppKit

struct AppKitServiceCardUpdate {
    let structuralChange: Bool
}

@MainActor
final class AppKitServiceCardView: LayerBackedView, ThemeApplying {
    static let headerHeight: CGFloat = 38

    private let model: TranslationModel
    private let provider: TranslationProviderID
    private let header = ServiceHeaderClickView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let speechButton = SpeechToggleButton(label: L10n.text("readTranslationAloud"))
    private let copyButton = AnimatedSymbolButton(symbol: "doc.on.doc", label: L10n.text("copyTranslation"), weight: .medium, scale: .small)
    private let chevronButton = AnimatedSymbolButton(symbol: "chevron.right", label: L10n.text("expandTranslation"), size: 11)
    private let bodyContainer = FlippedView()
    private let bodyView: AppKitServiceBodyView
    private var cardHeightConstraint: NSLayoutConstraint!
    private var bodyHeight: CGFloat = 0
    private var bodyContentHeight: CGFloat = 0
    private var lastResult: TranslationServiceResult?
    private var bodyNeedsLanguageRefresh = false
    private var lastDictionaryPreferences: AppKitServiceBodyView.DictionaryPreferences?
    private var lastShowsBody = false
    private var canToggle = false
    private var progressRunning = false

    var layoutHeightConstraints: [NSLayoutConstraint] { [cardHeightConstraint] }
    var renderedHeight: CGFloat { cardHeightConstraint.constant }
    private static let bodyHorizontalInsets = Design.Space.blockInset * 2
    var isRevealing: Bool { bodyView.isRevealing }
    var onVisibleTextChange: (() -> Void)?
    var onPreferredHeightChange: ((CGFloat, Bool) -> Void)?
    private(set) var preferredHeight: CGFloat = headerHeight

    init(model: TranslationModel, provider: TranslationProviderID) {
        self.model = model
        self.provider = provider
        self.bodyView = AppKitServiceBodyView(model: model)
        super.init(frame: .zero)
        ThemeManager.shared.register(self)
        cornerRadius = Design.Radius.block
        translatesAutoresizingMaskIntoConstraints = false

        header.translatesAutoresizingMaskIntoConstraints = false
        header.onClick = { [weak self] in self?.toggle() }
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.wantsLayer = true
        bodyContainer.layer?.masksToBounds = true
        bodyView.autoresizingMask = [.width]
        bodyContainer.addSubview(bodyView)
        addSubview(header)
        addSubview(bodyContainer)

        bodyView.onVisibleTextChange = { [weak self] in
            self?.onVisibleTextChange?()
        }
        configureHeader()
        cardHeightConstraint = heightAnchor.constraint(equalToConstant: Self.headerHeight)
        NSLayoutConstraint.activate([
            cardHeightConstraint,
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            bodyContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func applyTheme(_ palette: ThemePalette) {
        fillColor = palette.blockFill
        titleField.textColor = palette.ink
    }

    required init?(coder: NSCoder) { nil }

    @discardableResult
    func apply(
        _ result: TranslationServiceResult,
        hasCurrentResult: Bool,
        suppressBody: Bool,
        animated: Bool
    ) -> AppKitServiceCardUpdate {
        let previousShowsBody = lastShowsBody
        let persistedExpanded = model.isServiceExpanded(result.id)
        let visibleExpanded = ServiceResultPresentationPolicy.visibleExpanded(
            persistedExpanded: persistedExpanded,
            phase: result.phase
        )
        let showsBody = ServiceResultPresentationPolicy.showsBody(
            visibleExpanded: visibleExpanded,
            hasCurrentResult: hasCurrentResult,
            clearTransitionActive: suppressBody,
            phase: result.phase
        )
        canToggle = !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        header.acceptsClick = canToggle
        chevronButton.isEnabled = canToggle
        titleField.stringValue = result.title
        iconView.image = BrandIconRenderer.image(provider: result.id, serviceName: model.instance(result.id)?.brandName ?? result.title, size: Design.Icon.brand)
        updateProgress()
        let showsActions = showsBody && !result.text.isEmpty
        speechButton.alphaValue = showsActions ? 1 : 0
        copyButton.alphaValue = showsActions ? 1 : 0
        speechButton.isEnabled = showsActions
        copyButton.isEnabled = showsActions
        // 同一个“>”绕中心旋转 90° 指向下方；首次显示不做动画。
        chevronButton.setRotation(degrees: showsBody ? 90 : 0, animated: window != nil)
        chevronButton.updateLocalizedLabel(visibleExpanded ? L10n.text("collapseTranslation") : L10n.text("expandTranslation"))
        header.toolTip = canToggle ? chevronButton.toolTip : L10n.text("enterTextToUseThisService")
        header.setAccessibilityLabel(
            canToggle ? "\(result.title)，\(chevronButton.toolTip!)" : L10n.format("enterTextToUseThisService2", String(describing: result.title))
        )

        bodyView.renderingSuspended = !showsBody
        let dictionaryPreferences = result.id == .youdao && result.dictionaryEntry != nil
            ? AppKitServiceBodyView.DictionaryPreferences(model) : nil
        let bodyChanged = bodyNeedsLanguageRefresh || lastResult != result
            || showsBody != previousShowsBody || lastDictionaryPreferences != dictionaryPreferences
        if showsBody && bodyChanged {
            bodyNeedsLanguageRefresh = false
            bodyView.apply(result)
        }
        lastDictionaryPreferences = dictionaryPreferences
        lastResult = result
        lastShowsBody = showsBody
        bodyView.setAccessibilityHidden(!showsBody)
        bodyView.setAccessibilityExposed(showsBody)
        updateSpeechButton()

        updateProgress()
        let nextBodyHeight: CGFloat
        if showsBody {
            let contentWidth = max(180, bounds.width > 1 ? bounds.width - Self.bodyHorizontalInsets : 480)
            bodyContentHeight = ceil(bodyView.measuredHeight(for: contentWidth))
            nextBodyHeight = bodyContentHeight + 16
        } else {
            nextBodyHeight = 0
        }
        _ = setBodyHeight(nextBodyHeight, animated: animated)
        return AppKitServiceCardUpdate(
            structuralChange: previousShowsBody != showsBody
        )
    }

    override func layout() {
        super.layout()
        let width = max(0, bodyContainer.bounds.width - Self.bodyHorizontalInsets)
        bodyView.frame = NSRect(x: Design.Space.blockInset, y: 2, width: width, height: bodyContentHeight)
    }

    func updateVisibleBodyHeight() {
        updateProgress()
        guard lastShowsBody else { return }
        bodyContentHeight = ceil(bodyView.measuredHeight(for: max(180, bounds.width - Self.bodyHorizontalInsets)))
        _ = setBodyHeight(bodyContentHeight + 16, animated: false)
        needsLayout = true
    }

    private func updateProgress() {
        let running = lastResult?.phase.isRunning == true || bodyView.isRevealing
        progress.alphaValue = running ? 1 : 0
        if running != progressRunning {
            progressRunning = running
            running ? progress.startAnimation(nil) : progress.stopAnimation(nil)
        }
    }

    private func configureHeader() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityHidden(true)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = Design.Text.title.nsFont
        titleField.lineBreakMode = .byTruncatingTail
        progress.style = .spinning
        progress.controlSize = .small
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.isDisplayedWhenStopped = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let leftStack = NSStackView(views: [iconView, titleField, progress, spacer])
        leftStack.orientation = .horizontal
        leftStack.spacing = Design.Space.s
        leftStack.alignment = .centerY
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        let rightStack = NSStackView(views: [speechButton, copyButton, chevronButton])
        rightStack.orientation = .horizontal
        rightStack.spacing = Design.Space.xs
        rightStack.alignment = .centerY
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(leftStack)
        header.addSubview(rightStack)
        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: Design.Space.blockInset),
            leftStack.topAnchor.constraint(equalTo: header.topAnchor),
            leftStack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            leftStack.trailingAnchor.constraint(equalTo: rightStack.leadingAnchor, constant: -Design.Space.s),
            rightStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -Design.Space.iconButtonEdge),
            rightStack.topAnchor.constraint(equalTo: header.topAnchor),
            rightStack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Design.Icon.brand),
            iconView.heightAnchor.constraint(equalToConstant: Design.Icon.brand),
            progress.widthAnchor.constraint(equalToConstant: 14),
            progress.heightAnchor.constraint(equalToConstant: 14),
            speechButton.widthAnchor.constraint(equalToConstant: 26),
            speechButton.heightAnchor.constraint(equalToConstant: 26),
            copyButton.widthAnchor.constraint(equalToConstant: 26),
            copyButton.heightAnchor.constraint(equalToConstant: 26),
            // 箭头字形很窄，按钮收窄到 16，使其右边缘与朗读、复制图标一致（约 13），与左侧图标的 12 对称。
            chevronButton.widthAnchor.constraint(equalToConstant: 16),
            chevronButton.heightAnchor.constraint(equalToConstant: 26)
        ])
        speechButton.target = self
        speechButton.action = #selector(toggleSpeech)
        copyButton.target = self
        copyButton.action = #selector(copyResult)
        chevronButton.target = self
        chevronButton.action = #selector(toggleFromButton)
    }

    @discardableResult
    private func setBodyHeight(_ value: CGFloat, animated: Bool) -> Bool {
        let normalized = max(0, value)
        guard abs(bodyHeight - normalized) > 0.5 else { return false }
        bodyHeight = normalized
        preferredHeight = Self.headerHeight + normalized
        cardHeightConstraint.constant = preferredHeight
        onPreferredHeightChange?(preferredHeight, animated)
        return true
    }

    private func toggle() {
        guard canToggle else { return }
        model.setServiceExpanded(provider, expanded: !model.isServiceExpanded(provider))
    }

    @objc private func toggleFromButton() { toggle() }

    @objc private func toggleSpeech() {
        guard let result = lastResult else { return }
        model.speech.toggle(
            content: speechContent,
            text: result.text,
            declaredLanguage: provider == .ecdict ? nil : (model.resolvedTarget ?? model.target)
        )
        updateSpeechButton()
    }

    @objc private func copyResult() {
        if model.copyResult(provider) { copyButton.flashConfirmation() }
    }

    private var speechContent: SpeechContent { .result(of: provider) }

    func refreshInterfaceLanguage() {
        copyButton.updateLocalizedLabel(L10n.text("copyTranslation"))
        bodyNeedsLanguageRefresh = true
        bodyView.invalidateLocalizedActions()
    }

    private func updateSpeechButton() {
        let text = lastResult?.text ?? ""
        let language = provider == .ecdict ? nil : (model.resolvedTarget ?? model.target)
        speechButton.isEnabled = speechButton.isEnabled && model.speech.canSpeak(text: text, declaredLanguage: language)
        speechButton.apply(
            model.speech.appearance(for: speechContent),
            symbol: model.speech.icon(for: speechContent),
            label: model.speech.availabilityLabel(content: speechContent, text: text, declaredLanguage: language)
        )
    }
}

private final class ServiceHeaderClickView: FlippedView {
    var onClick: (() -> Void)?
    var acceptsClick = true

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit is NSButton { return hit }
        return acceptsClick && bounds.contains(point) ? self : hit
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard acceptsClick else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), !(hitTest(point) is NSButton) else { return }
        onClick?()
    }
}
