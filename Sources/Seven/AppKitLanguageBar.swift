import AppKit

/// Content shown on the two language bar buttons: actual language name and optional "Auto" tag.
struct LanguageBarLabel: Equatable {
    let name: String
    let note: String?

    static func source(source: String, detected: String?, hasText: Bool) -> LanguageBarLabel {
        if source != LanguageCatalog.automatic { return .init(name: LanguageCatalog.name(source), note: nil) }
        if hasText, let detected { return .init(name: LanguageCatalog.name(detected), note: L10n.text("auto")) }
        return .init(name: L10n.text("languageBar.detectAuto"), note: nil)
    }

    static func target(target: String, resolved: String?) -> LanguageBarLabel {
        if target != LanguageCatalog.automatic { return .init(name: LanguageCatalog.name(target), note: nil) }
        if let resolved { return .init(name: LanguageCatalog.name(resolved), note: L10n.text("auto")) }
        return .init(name: L10n.text("languageBar.chooseAuto"), note: nil)
    }
}

@MainActor
final class AppKitLanguageBar: LayerBackedView, ThemeApplying {
    static let preferredHeight: CGFloat = 38

    private let model: TranslationModel
    private let sourceButton = LanguageMenuButton(accessibilityLabel: L10n.text("sourceLanguage"))
    private let targetButton = LanguageMenuButton(accessibilityLabel: L10n.text("targetLanguage"))
    private let swapButton = AnimatedSymbolButton(symbol: Design.Icon.swapLanguages, label: L10n.text("swapLanguages"))

    init(model: TranslationModel) {
        self.model = model
        super.init(frame: .zero)
        ThemeManager.shared.register(self)
        cornerRadius = Design.Radius.block
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [sourceButton, swapButton, targetButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = Design.Space.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.preferredHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Space.xs),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Space.xs),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Design.Space.xs),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Space.xs),
            sourceButton.widthAnchor.constraint(equalTo: targetButton.widthAnchor),
            sourceButton.heightAnchor.constraint(equalTo: stack.heightAnchor),
            targetButton.heightAnchor.constraint(equalTo: stack.heightAnchor),
            swapButton.widthAnchor.constraint(equalToConstant: 36),
            swapButton.heightAnchor.constraint(equalTo: stack.heightAnchor)
        ])

        sourceButton.menuProvider = { [weak self] in self?.sourceMenu() ?? NSMenu() }
        targetButton.menuProvider = { [weak self] in self?.targetMenu() ?? NSMenu() }
        swapButton.target = self
        swapButton.action = #selector(swapLanguages)
        applyModel()
    }

    func applyTheme(_ palette: ThemePalette) {
        fillColor = palette.blockFill
    }

    required init?(coder: NSCoder) { nil }

    func refreshInterfaceLanguage() {
        sourceButton.setAccessibilityLabel(L10n.text("sourceLanguage"))
        targetButton.setAccessibilityLabel(L10n.text("targetLanguage"))
        applyModel()
    }

    func applyModel() {
        let source = LanguageBarLabel.source(
            source: model.source,
            detected: model.detectedSource, hasText: model.hasInputText
        )
        let target = LanguageBarLabel.target(target: model.target, resolved: model.displayTarget)
        sourceButton.apply(source, help: sourceHelp(source))
        targetButton.apply(target, help: model.target == TranslationModel.automaticTarget
            ? model.automaticTargetTitle : L10n.text("theTargetLanguageIsFixedChooseChoose"))
        swapButton.isEnabled = model.canSwapLanguages
        swapButton.toolTip = model.swapTitle
        swapButton.setAccessibilityLabel(model.swapTitle)
    }

    private func sourceHelp(_ label: LanguageBarLabel) -> String {
        if label.note != nil { return L10n.format("detectedClickToSetTheSourceLanguage", label.name) }
        return model.source == LanguageCatalog.automatic
            ? L10n.text("detectTheSourceLanguageAutomatically")
            : L10n.text("theSourceLanguageIsFixedChooseDetect")
    }

    // MARK: Menus

    func sourceMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(L10n.text("detectAutomatically"), checked: model.source == LanguageCatalog.automatic) {
            [weak self] in self?.model.setSource(LanguageCatalog.automatic)
        })
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: L10n.text("setLanguage")))
        addLanguages(to: menu, selected: model.source) { [weak self] in self?.model.setSource($0) }
        return menu
    }

    func targetMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(L10n.text("chooseAutomatically"), checked: model.target == TranslationModel.automaticTarget) {
            [weak self] in self?.model.setTarget(TranslationModel.automaticTarget)
        })
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: L10n.text("setLanguage")))
        addLanguages(to: menu, selected: model.target) { [weak self] in self?.model.setTarget($0) }
        return menu
    }

    /// Lists common languages first and places the rest in a "More Languages" submenu; checks "More Languages" when the current selection is inside it.
    private func addLanguages(to menu: NSMenu, selected: String?, choose: @escaping (String) -> Void) {
        for code in model.commonLanguages {
            menu.addItem(item(LanguageCatalog.name(code), checked: selected == code) { choose(code) })
        }
        let others = model.otherLanguages
        guard !others.isEmpty else { return }
        let more = NSMenuItem(title: L10n.text("moreLanguages"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for code in others {
            submenu.addItem(item(LanguageCatalog.name(code), checked: selected == code) { choose(code) })
        }
        more.submenu = submenu
        more.state = others.contains { $0 == selected } ? .on : .off
        menu.addItem(more)
    }

    private func item(_ title: String, checked: Bool, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: action)
        item.state = checked ? .on : .off
        return item
    }

    @objc private func swapLanguages() {
        model.swapLanguages()
        // Flips ⇌ vertically to ⇋ (and back on next click) so arrow direction reflects the swap.
        swapButton.setMirrored(!swapButton.isMirrored, animated: true)
        applyModel()
    }
}

/// Menu item that executes a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

/// Language button: shows "Language · Tag" with chevron, fades in background on hover, and pops up a native menu on click.
final class LanguageMenuButton: NSButton, ThemeApplying {
    private var palette = ThemePalette.system
    var menuProvider: (() -> NSMenu)?
    /// Used only where a wider hit target is needed; preserves the equal-width layout of the translation language bar.
    var horizontalContentInset: CGFloat = 0 { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + horizontalContentInset * 2, height: base.height)
    }
    private(set) var label = LanguageBarLabel(name: "", note: nil)
    private var isHovering = false { didSet { updateFill(animated: true) } }
    private var isPressed = false { didSet { updateFill(animated: true) } }
    private var hoverArea: NSTrackingArea?

    init(accessibilityLabel: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Design.Radius.control
        isBordered = false
        bezelStyle = .flexiblePush
        imagePosition = .noImage
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(accessibilityLabel)
        setButtonType(.momentaryChange)
        ThemeManager.shared.register(self)
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ label: LanguageBarLabel, help: String) {
        toolTip = help
        guard label != self.label else { return }
        self.label = label
        updateTitle()
    }

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        if !label.name.isEmpty { updateTitle() }
        updateFill(animated: false)
    }

    private func updateTitle() {
        let title = NSMutableAttributedString(string: label.name, attributes: [
            .font: Design.Text.title.nsFont, .foregroundColor: palette.ink
        ])
        if let note = label.note {
            title.append(NSAttributedString(string: " · \(note)", attributes: [
                .font: Design.Text.body.nsFont, .foregroundColor: palette.inkSecondary
            ]))
        }
        title.append(NSAttributedString(string: " "))
        title.append(Self.chevron(alignedTo: Design.Text.title.nsFont, ink: palette.ink))
        attributedTitle = title
        setAccessibilityValue(label.note.map { "\(label.name)，\($0)" } ?? label.name)
    }

    /// Up/down chevrons embedded as a text attachment, vertically centered on the font midline.
    /// Using it as a button image aligns it with the text baseline, about 1.5pt lower than the text center.
    static func chevron(alignedTo font: NSFont, ink: NSColor) -> NSAttributedString {
        let configuration = NSImage.SymbolConfiguration(pointSize: Design.Icon.tiny, weight: .semibold)
            .applying(.init(paletteColors: [ink]))  // Match the language name color
        guard let image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return NSAttributedString() }
        let attachment = NSTextAttachment()
        attachment.image = image
        let midline = (font.ascender + font.descender) / 2
        attachment.bounds = NSRect(x: 0, y: midline - image.size.height / 2,
                                   width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    private func updateFill(animated: Bool) {
        guard let layer else { return }
        let color: NSColor = !isEnabled ? ThemePalette.clear
            : isPressed ? palette.controlPressedFill
            : isHovering ? palette.controlHoverFill : ThemePalette.clear
        var resolved: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        if animated, !Design.Motion.reduced {
            let animation = CABasicAnimation(keyPath: "backgroundColor")
            animation.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
            animation.toValue = resolved
            animation.duration = Design.Motion.fast
            layer.add(animation, forKey: "fill")
        }
        layer.backgroundColor = resolved
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill(animated: false)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let menu = menuProvider?() else { return }
        isPressed = true
        // Commit the pressed background before the pop-up menu enters its modal tracking loop.
        CATransaction.flush()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + Design.Space.xs : -Design.Space.xs), in: self)
        isPressed = false
        isHovering = bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        guard let menu = menuProvider?() else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY : 0), in: self)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
}
