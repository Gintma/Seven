import AppKit

@MainActor
final class ResultMarkdownCodeHeader: FlippedView {
    static let attribute = NSAttributedString.Key("SevenMarkdownCodeHeader")
    static let height: CGFloat = 24

    struct Content {
        let blockIndex: Int
        let language: String?
        let code: String
    }

    private let languageLabel = NSTextField(labelWithString: "")
    private let copyButton = AnimatedSymbolButton(symbol: "doc.on.doc", label: L10n.text("copyCode"), size: 13,
                                                 weight: .medium, scale: .small)
    private var code = ""

    var accessibleControls: [NSView] {
        languageLabel.isHidden ? [copyButton] : [languageLabel, copyButton]
    }

    init() {
        super.init(frame: .zero)
        languageLabel.font = Design.Text.note.nsFont
        languageLabel.lineBreakMode = .byTruncatingTail
        languageLabel.translatesAutoresizingMaskIntoConstraints = false
        languageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(languageLabel)
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        addSubview(copyButton)
        NSLayoutConstraint.activate([
            languageLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            languageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            languageLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -Design.Space.s),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            copyButton.topAnchor.constraint(equalTo: topAnchor),
            copyButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 28)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ content: Content, frame: NSRect, palette: ThemePalette) {
        if self.frame != frame { self.frame = frame }
        code = content.code
        let label = content.language ?? ""
        if languageLabel.stringValue != label { languageLabel.stringValue = label }
        languageLabel.isHidden = content.language == nil
        languageLabel.textColor = palette.inkSecondary
        copyButton.applyTheme(palette)
        layoutSubtreeIfNeeded()
    }

    func refreshLanguage() {
        copyButton.updateLocalizedLabel(L10n.text("copyCode"))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === copyButton ? hit : nil
    }

    @discardableResult
    func copyCode(to pasteboard: NSPasteboard) -> Bool {
        guard !code.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(code, forType: .string)
    }

    @objc private func copyClicked() {
        if copyCode(to: .general) { copyButton.flashConfirmation() }
    }
}
