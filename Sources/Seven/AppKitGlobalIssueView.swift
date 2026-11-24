import AppKit

@MainActor
final class AppKitGlobalIssueView: LayerBackedView, ThemeApplying {
    private var palette = ThemePalette.system
    private let model: TranslationModel
    private let icon = NSImageView()
    private let message = NSTextField.wrappingLabel(
        "",
        font: Design.Text.body.nsFont,
        color: ThemePalette.system.inkSecondary
    )
    private let retryButton = NSButton(title: L10n.text("retry"), target: nil, action: nil)
    private let recoveryButton = NSButton(title: "", target: nil, action: nil)
    private var heightConstraint: NSLayoutConstraint!
    var layoutHeightConstraints: [NSLayoutConstraint] { [heightConstraint] }
    var renderedHeight: CGFloat { heightConstraint.constant }
    private(set) var preferredHeight: CGFloat = 0
    var onPreferredHeightChange: ((CGFloat, Bool) -> Void)?

    init(model: TranslationModel) {
        self.model = model
        super.init(frame: .zero)
        cornerRadius = Design.Radius.block
        translatesAutoresizingMaskIntoConstraints = false

        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: L10n.text("warning"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        message.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: [retryButton, recoveryButton])
        actions.orientation = .horizontal
        actions.spacing = Design.Space.s
        actions.alignment = .top
        actions.translatesAutoresizingMaskIntoConstraints = false
        retryButton.bezelStyle = .push
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retry)
        recoveryButton.bezelStyle = .push
        recoveryButton.controlSize = .small
        recoveryButton.target = self
        recoveryButton.action = #selector(recover)

        addSubview(icon)
        addSubview(message)
        addSubview(actions)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        let messageBottom = message.bottomAnchor.constraint(
            lessThanOrEqualTo: bottomAnchor,
            constant: -Design.Space.blockInset
        )
        messageBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heightConstraint,
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Space.blockInset),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: Design.Space.m),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            message.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Design.Space.s),
            message.topAnchor.constraint(equalTo: topAnchor, constant: Design.Space.m),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: message.trailingAnchor, constant: Design.Space.s),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Space.iconButtonEdge),
            actions.topAnchor.constraint(equalTo: topAnchor, constant: Design.Space.s),
            messageBottom
        ])
        ThemeManager.shared.register(self)
        applyModel(animated: false)
    }

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        fillColor = palette.warningFill
        strokeColor = palette.warningStroke
        icon.contentTintColor = palette.warning
        message.textColor = palette.inkSecondary
        retryButton.applyTheme(palette, title: L10n.text("retry"))
        recoveryButton.applyTheme(palette, title: model.recoveryTitle ?? "")
    }

    required init?(coder: NSCoder) { nil }

    func refreshInterfaceLanguage() {
        retryButton.applyTheme(palette, title: L10n.text("retry"))
        icon.image?.accessibilityDescription = L10n.text("warning")
    }

    @discardableResult
    func applyModel(animated: Bool) -> Bool {
        let issue = model.serviceResults.isEmpty ? model.errorMessage : nil
        message.stringValue = issue ?? ""
        retryButton.isHidden = model.input.isEmpty
        recoveryButton.applyTheme(palette, title: model.recoveryTitle ?? "")
        recoveryButton.isHidden = model.recoveryTitle == nil
        isHidden = issue == nil
        let next: CGFloat
        if issue == nil {
            next = 0
        } else {
            let available = max(160, bounds.width - 210)
            let textHeight = ceil(
                NSString(string: issue ?? "").boundingRect(
                    with: NSSize(width: available, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: Design.Text.body.nsFont]
                ).height
            )
            next = max(42, textHeight + 23)
        }
        let changed = abs(preferredHeight - next) > 0.5
        preferredHeight = next
        heightConstraint.constant = next
        if changed { onPreferredHeightChange?(next, animated) }
        return changed
    }

    override func layout() {
        super.layout()
        if !isHidden { _ = applyModel(animated: false) }
    }

    @objc private func retry() { model.translate() }
    @objc private func recover() { model.performRecovery() }
}
