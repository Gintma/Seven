import AppKit
import Combine

@MainActor
final class AppKitTitlebarControls: NSView {
    private static let buttonHeight: CGFloat = 28
    /// 每个按钮在图形左右各留出的点击余量。
    private static let hitPadding = Design.Space.xs
    /// 相邻图形之间的可见空隙，与图标到窗口顶、到输入框的距离一致（约 12），让四个图标读作一组。
    private static let iconGap = Design.Space.m
    private let model: TranslationModel
    private let pinButton = AnimatedSymbolButton(symbol: "pin", label: L10n.text("pinWindowP"))
    private let historyButton = SymbolButton(symbol: "clock.arrow.circlepath", label: L10n.text("history.title"))
    private let screenshotButton = SymbolButton(symbol: "viewfinder", label: L10n.text("translateScreenshot"))
    private let settingsButton = SymbolButton(symbol: "slider.horizontal.3", label: L10n.text("translationServiceSettings"))
    private var lastPinned: Bool?
    private var cancellable: AnyCancellable?

    init(model: TranslationModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 132, height: 30))
        translatesAutoresizingMaskIntoConstraints = true

        let buttons = [pinButton, historyButton, screenshotButton, settingsButton]
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = Self.iconGap - 2 * Self.hitPadding
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // 各图形宽度不同（图钉窄、历史宽），按实际墨迹宽度定按钮宽，可见空隙才会相等。
        let symbols = [["pin", "pin.fill"], ["clock.arrow.circlepath"], ["viewfinder"], ["slider.horizontal.3"]]
        for (button, names) in zip(buttons, symbols) {
            let inkWidth = names.compactMap {
                Design.Icon.symbol($0)?.withSymbolConfiguration(.init(pointSize: Design.Icon.action, weight: .regular))
            }.map(\.inkWidth).max() ?? Design.Icon.action
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: ceil(inkWidth) + 2 * Self.hitPadding),
                button.heightAnchor.constraint(equalToConstant: Self.buttonHeight)
            ])
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            // 扣除点击余量，让最右侧图形的右边缘与下方内容边线（Space.l）对齐。
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Design.Space.l - Self.hitPadding)),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        pinButton.target = self
        pinButton.action = #selector(togglePin)
        historyButton.target = self
        historyButton.action = #selector(openHistory)
        screenshotButton.target = self
        screenshotButton.action = #selector(startScreenshot)
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)

        updatePinButton()
        cancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updatePinButton() }
        }
    }

    required init?(coder: NSCoder) { nil }

    @objc private func togglePin() { model.pinned.toggle() }
    @objc private func openHistory() { model.openHistory() }
    @objc private func startScreenshot() { model.startScreenshot() }
    @objc private func openSettings() { model.openSettings() }

    func refreshInterfaceLanguage() {
        historyButton.updateLocalizedLabel(L10n.text("history.title"))
        screenshotButton.updateLocalizedLabel(L10n.text("translateScreenshot"))
        settingsButton.updateLocalizedLabel(L10n.text("translationServiceSettings"))
        updatePinButton()
    }

    private func updatePinButton() {
        let pinned = model.pinned
        let changed = lastPinned != nil && lastPinned != pinned
        lastPinned = pinned
        pinButton.setSymbol(pinned ? "pin.fill" : "pin", animated: changed)
        if changed, pinned { pinButton.wiggle() }
        pinButton.setThemeTint(pinned ? .accent : .inkSecondary)
        pinButton.toolTip = model.pinned ? L10n.text("unpinWindowP") : L10n.text("pinWindowP")
        pinButton.updateLocalizedLabel(
            model.pinned ? L10n.text("unpinWindow") : L10n.text("pinWindow"),
            toolTip: pinButton.toolTip
        )
    }
}
