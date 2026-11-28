import AppKit

/// Shares the refresh clock with the dot-matrix orb and sweeps a highlight across the existing glyphs of the same text control, with no secondary layout or mask.
@MainActor
final class ShimmerStatusLabel: NSTextField {
    private var palette = ThemePalette.system

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        textColor = palette.hudText
        needsDisplay = true
    }

    private(set) var isShimmering = false
    private var startedAt: TimeInterval = 0
    var hasSweepAnimation: Bool { isShimmering && window != nil && !Design.Motion.reduced }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func setLoading(_ loading: Bool) {
        if loading && !isShimmering { startedAt = ProcessInfo.processInfo.systemUptime }
        isShimmering = loading
        refreshShimmer()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshShimmer() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshShimmer() }
    func refreshShimmer() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard hasSweepAnimation else {
            super.draw(dirtyRect)
            return
        }
        drawSweep(elapsed: ProcessInfo.processInfo.systemUptime - startedAt)
    }

    /// Narrow vertical strips only change stroke color; every draw pass reuses the same cell so baselines and glyphs stay pixel-aligned.
    func drawSweep(elapsed: TimeInterval) {
        guard let textCell = cell as? NSTextFieldCell else { return }
        let phase = elapsed.truncatingRemainder(dividingBy: Design.ReplacementHUD.shimmerDuration)
            / Design.ReplacementHUD.shimmerDuration
        let center = bounds.width * (phase * 1.8 - 0.4)
        let spread = max(1, bounds.width * Design.ReplacementHUD.shimmerSpread)
        let saved = textCell.textColor
        defer { textCell.textColor = saved }
        for x in stride(from: bounds.minX, to: bounds.maxX, by: 1) {
            let distance = abs(x - center) / spread
            let strength = pow(max(0, 1 - distance), Design.ReplacementHUD.shimmerConcentration)
            textCell.textColor = palette.hudText.blended(withFraction: strength, of: palette.hudHighlight)
                ?? palette.hudText
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: x, y: bounds.minY, width: 1, height: bounds.height)).addClip()
            textCell.draw(withFrame: bounds, in: self)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
