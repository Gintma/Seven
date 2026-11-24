import AppKit

/// 工具按钮：只显示 SF Symbol。平时为次要色，悬停时加深为正文色；
/// 调用方设成其他颜色（例如表示“已钉住”的强调色）时，悬停不改变它。
class SymbolButton: NSButton, ThemeApplying {
    private(set) var palette = ThemePalette.system
    private var tintToken: ThemeToken? = .inkSecondary
    private var requestedTint: NSColor? = ThemePalette.system.inkSecondary
    private var isHovering = false
    private var hoverArea: NSTrackingArea?

    init(symbol: String, label: String, size: CGFloat = Design.Icon.action) {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        ThemeManager.shared.register(self)
        translatesAutoresizingMaskIntoConstraints = false
        setSymbol(symbol, size: size)
        toolTip = label
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { nil }

    func setThemeTint(_ token: ThemeToken) {
        tintToken = token
        requestedTint = palette[token]
        applyTint()
    }

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        if let tintToken { setThemeTint(tintToken) }
    }

    override var contentTintColor: NSColor? {
        get { requestedTint }
        set {
            tintToken = nil
            requestedTint = newValue
            applyTint()
        }
    }

    override var isEnabled: Bool {
        didSet { applyTint() }
    }

    /// 当前实际显示的颜色（含悬停效果）。
    var displayedTint: NSColor? { super.contentTintColor }

    /// 实际显示的颜色已变化；用内部视图绘制图标的子类在这里转发。
    func displayedTintDidChange(_ color: NSColor?) {}

    private func applyTint() {
        let hovered = isHovering && isEnabled && requestedTint == palette.inkSecondary
        let shown = hovered ? palette.ink : requestedTint
        super.contentTintColor = shown
        displayedTintDidChange(shown)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
        applyTint()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
        applyTint()
    }

    func setSymbol(_ name: String, size: CGFloat = Design.Icon.action) {
        image = Design.Icon.symbol(name, description: toolTip)?.withSymbolConfiguration(.init(pointSize: size, weight: .regular))
    }
}
