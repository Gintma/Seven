import AppKit

/// Speech button: displays a speaker, loading spinner, animated speaker, pause, or resume icon according to SpeechButtonAppearance.
/// Icons are drawn by an internal NSImageView; clicks are always handled by the button itself.
final class SpeechToggleButton: SymbolButton {
    private let iconView = PassthroughImageView()
    private let spinner = NSProgressIndicator()
    private var waveTimer: Timer?
    private var waveFrame = 0
    private(set) var appearanceState: SpeechButtonAppearance?
    /// Currently displayed symbol name, or nil while loading; used by tests to verify the button is never blank.
    private(set) var displayedSymbol: String?

    /// Alternates between two frames while playing short content.
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
        // Size to the widest speaker frame and align speaker icons leading so the speaker body stays stationary as sound waves animate.
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

    /// Called on every model refresh; when appearance is unchanged, updates only the tooltip to avoid restarting animations.
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
        // Show a static speaker icon when Reduce Motion is enabled.
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
            // When the floating panel is rebuilt, the button is removed and reattached; restore animation based on current state.
            startWaves()
        }
    }

    /// Inner icon and spinner do not accept clicks; otherwise the card header treats the click as non-button and collapses the card.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point).map { _ in self }
    }
}

private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
