import AppKit

/// 朗读按钮：按 SpeechButtonAppearance 显示喇叭、加载转圈、动态喇叭、暂停或继续。
/// 图标由内部 NSImageView 绘制；点击始终由按钮本身处理。
final class SpeechToggleButton: SymbolButton {
    private let iconView = PassthroughImageView()
    private let spinner = NSProgressIndicator()
    private var waveTimer: Timer?
    private var waveFrame = 0
    private(set) var appearanceState: SpeechButtonAppearance?
    /// 当前显示的符号名，加载中为 nil；供测试确认按钮任何时候都不会是空白。
    private(set) var displayedSymbol: String?

    /// 短内容播放时在两帧之间交替。
    static let waveFrames = ["speaker.wave.1", "speaker.wave.2"]
    private static let waveInterval = Design.Motion.speakerFrame
    private let glyphConfiguration: NSImage.SymbolConfiguration

    init(label: String, symbolSize: CGFloat = Design.Icon.action) {
        glyphConfiguration = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
        super.init(symbol: "speaker.wave.2", label: label)
        image = nil
        iconView.contentTintColor = displayedTint
        iconView.symbolConfiguration = glyphConfiguration
        iconView.imageScaling = .scaleNone
        iconView.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(spinner)
        // 以最宽的喇叭帧定宽，喇叭类图标靠左对齐：声波增减时喇叭本体不左右移动。
        let speakerWidth = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)?
            .withSymbolConfiguration(glyphConfiguration)?.size.width ?? 20
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: ceil(speakerWidth)),
            iconView.heightAnchor.constraint(equalTo: heightAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14)
        ])
        apply(.idle, symbol: "speaker.wave.2", label: label)
    }

    required init?(coder: NSCoder) { nil }

    override func displayedTintDidChange(_ color: NSColor?) {
        iconView.contentTintColor = color
    }

    override var isEnabled: Bool {
        didSet { iconView.alphaValue = isEnabled ? 1 : Design.Opacity.disabled }
    }

    /// 模型每次刷新都会调用；外观未变时只更新提示文字，避免重启动画。
    func apply(_ appearance: SpeechButtonAppearance, symbol: String, label: String) {
        toolTip = label
        setAccessibilityLabel(label)
        guard appearance != appearanceState else { return }
        appearanceState = appearance
        stopWaves()

        switch appearance {
        case .loading:
            iconView.isHidden = true
            displayedSymbol = nil
            spinner.startAnimation(nil)
        case .playingShort:
            spinner.stopAnimation(nil)
            iconView.isHidden = false
            startWaves()
        case .idle, .playingLong, .paused:
            spinner.stopAnimation(nil)
            iconView.isHidden = false
            show(symbol)
        }
    }

    private func show(_ symbol: String) {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip) else { return }
        iconView.imageAlignment = symbol.hasPrefix("speaker") ? .alignLeft : .alignCenter
        iconView.image = image
        displayedSymbol = symbol
    }

    private func startWaves() {
        waveFrame = 0
        show(Self.waveFrames[waveFrame])
        // 开启“减弱动态效果”时只显示静止喇叭。
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        waveTimer = Timer.scheduledTimer(withTimeInterval: Self.waveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.waveFrame = (self.waveFrame + 1) % Self.waveFrames.count
                self.show(Self.waveFrames[self.waveFrame])
            }
        }
    }

    private func stopWaves() {
        waveTimer?.invalidate()
        waveTimer = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopWaves()
        } else if appearanceState == .playingShort, waveTimer == nil {
            // 浮窗重建时按钮会被移出再挂回，按当前状态恢复动画。
            startWaves()
        }
    }

    /// 内部图标与转圈不接收点击：否则卡片标题栏会把点击判定为“不是按钮”而收起卡片。
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point).map { _ in self }
    }
}

private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
