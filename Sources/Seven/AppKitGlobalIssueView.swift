import AppKit

@MainActor
final class AppKitGlobalIssueView: LayerBackedView, ThemeApplying {
    private static let iconSize: CGFloat = 16
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
    private let actions = NSStackView()
    private var messageTrailing: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var measuredWidth: CGFloat = 0
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

        actions.addArrangedSubview(retryButton)
        actions.addArrangedSubview(recoveryButton)
        actions.detachesHiddenViews = true
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
        messageTrailing = message.trailingAnchor.constraint(equalTo: trailingAnchor)
        let messageBottom = message.bottomAnchor.constraint(
            lessThanOrEqualTo: bottomAnchor,
            constant: -Design.Space.blockInset
        )
        messageBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heightConstraint,
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Space.blockInset),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: Design.Space.m),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            message.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Design.Space.s),
            message.topAnchor.constraint(equalTo: topAnchor, constant: Design.Space.m),
            messageTrailing,
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
        retryButton.isHidden = !model.canRetryGlobalIssue
        recoveryButton.applyTheme(palette, title: model.recoveryTitle ?? "")
        recoveryButton.isHidden = model.recoveryTitle == nil
        actions.isHidden = retryButton.isHidden && recoveryButton.isHidden
        isHidden = issue == nil
        return updateHeight(animated: animated)
    }

    @discardableResult
    private func updateHeight(animated: Bool) -> Bool {
        measuredWidth = bounds.width
        let next: CGFloat
        if isHidden {
            next = 0
        } else {
            let buttonSizes = [retryButton, recoveryButton].filter { !$0.isHidden }.map(\.fittingSize)
            let actionsInset = buttonSizes.isEmpty
                ? Design.Space.blockInset
                : Design.Space.iconButtonEdge + buttonSizes.reduce(0) { $0 + $1.width + actions.spacing }
            let textLeading = Design.Space.blockInset + Self.iconSize + Design.Space.s
            let textWidth = max(1, measuredWidth - textLeading - actionsInset)
            messageTrailing.constant = -actionsInset
            message.preferredMaxLayoutWidth = textWidth
            let textBounds = NSRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)
            let textHeight = ceil(message.cell?.cellSize(forBounds: textBounds).height ?? 0)
            let messageBottom = Design.Space.m + max(Self.iconSize, textHeight)
            let actionsBottom = Design.Space.s + (buttonSizes.map(\.height).max() ?? 0)
            next = max(messageBottom, actionsBottom) + Design.Space.blockInset
        }
        let changed = abs(preferredHeight - next) > 0.5
        preferredHeight = next
        heightConstraint.constant = next
        if changed { onPreferredHeightChange?(next, animated) }
        return changed
    }

    override func layout() {
        super.layout()
        if !isHidden, abs(bounds.width - measuredWidth) > 0.5 {
            updateHeight(animated: false)
        }
    }

    @objc private func retry() { model.translate() }
    @objc private func recover() { model.performRecovery() }
}
