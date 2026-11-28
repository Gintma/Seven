import AppKit

/// Button with action feedback: icon crossfade replacement, center rotation, bounce/wiggle, and drawn checkmark confirmation.
/// Icons are drawn by internal views; clicks are always handled by the button itself.
final class AnimatedSymbolButton: SymbolButton {
    private let iconView = RotatingIconView()
    private let checkmarkView = CheckmarkView()
    private(set) var symbolName: String
    private let symbolSize: CGFloat
    private let symbolWeight: NSFont.Weight
    private let symbolScale: NSImage.SymbolScale
    private var confirmationGeneration = 0
    private(set) var isShowingConfirmation = false
    static let confirmationDuration = Design.Motion.hold
    static let fadeDuration = Design.Motion.fast
    /// Confirmation animation: icon fades out -> checkmark draws in.
    static let iconOutDuration = Design.Motion.fast
    static let checkmarkDrawDuration = Design.Motion.standard
    static let rotationDuration = Design.Motion.standard

    /// Taller symbols (such as vertically stacked doc.on.doc) can use `.small` scale with `.medium` weight
    /// so their visual size and stroke weight match neighboring icons.
    init(symbol: String, label: String, size: CGFloat = 16,
         weight: NSFont.Weight = .regular, scale: NSImage.SymbolScale = .medium) {
        symbolName = symbol
        symbolSize = size
        symbolWeight = weight
        symbolScale = scale
        super.init(symbol: symbol, label: label, size: size)
        image = nil
        iconView.imageScaling = .scaleNone
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = super.contentTintColor
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        iconView.setImage(symbolImage(symbol), fade: 0)
        checkmarkView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkmarkView)
        NSLayoutConstraint.activate([
            checkmarkView.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkmarkView.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmarkView.widthAnchor.constraint(equalToConstant: size),
            checkmarkView.heightAnchor.constraint(equalToConstant: size)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func applyTheme(_ palette: ThemePalette) {
        super.applyTheme(palette)
        checkmarkView.updateStrokeColor(palette.accent)
    }

    override func displayedTintDidChange(_ color: NSColor?) {
        iconView.contentTintColor = color
    }

    override var isEnabled: Bool {
        didSet { if !isShowingConfirmation { iconView.alphaValue = restingIconAlpha } }
    }

    private var restingIconAlpha: CGFloat { isEnabled ? 1 : Design.Opacity.disabled }

    /// Also called by the superclass during initialization before internal icon views are added; safe to ignore.
    override func setSymbol(_ name: String, size: CGFloat = 16) {
        setSymbol(name, animated: false)
    }

    /// Crossfades to replace the icon without scaling or shifting.
    func setSymbol(_ name: String, animated: Bool) {
        guard iconView.superview != nil else { return }
        guard name != symbolName || iconView.image == nil else { return }
        symbolName = name
        iconView.setImage(symbolImage(name), fade: animated ? Self.fadeDuration : 0)
    }

    /// Rotates around the icon center to the given angle (positive is clockwise).
    func setRotation(degrees: CGFloat, animated: Bool) {
        iconView.setRotation(degrees: degrees, duration: animated ? Self.rotationDuration : 0)
    }

    /// Flips vertically (e.g. ⇌ to ⇋) and holds the flipped state; uses `standard` duration.
    func setMirrored(_ mirrored: Bool, animated: Bool) {
        iconView.setMirrored(mirrored, duration: animated ? Self.rotationDuration : 0)
    }

    var isMirrored: Bool { iconView.isMirrored }
    var displayedScaleY: CGFloat { iconView.displayedScaleY }
    var displayedRotationDegrees: CGFloat { iconView.displayedDegrees }

    /// Wiggles horizontally (available on macOS 15+); no-op on earlier macOS versions.
    func wiggle() {
        guard !Self.reduceMotion else { return }
        if #available(macOS 15.0, *) {
            iconView.addSymbolEffect(.wiggle)
        }
    }

    /// Success feedback: icon fades out and an accent-colored checkmark draws in; after a brief pause, the checkmark fades out and the icon fades back.
    /// Clicking again during confirmation only resets the timer without redrawing the checkmark.
    func flashConfirmation() {
        confirmationGeneration += 1
        let generation = confirmationGeneration
        if !isShowingConfirmation {
            isShowingConfirmation = true
            let reduceMotion = Self.reduceMotion
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : Self.iconOutDuration
                iconView.animator().alphaValue = 0
            }
            checkmarkView.draw(
                color: palette.accent,
                lineWidth: Self.checkmarkLineWidth(for: symbolSize),
                duration: reduceMotion ? 0 : Self.checkmarkDrawDuration,
                delay: reduceMotion ? 0 : Self.iconOutDuration * 0.6
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmationDuration) { [weak self] in
            guard let self, self.confirmationGeneration == generation, self.isShowingConfirmation else { return }
            self.isShowingConfirmation = false
            self.checkmarkView.hide(fade: Self.fadeDuration)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                self.iconView.animator().alphaValue = self.restingIconAlpha
            }
        }
    }

    /// Matches the stroke width of 16 pt regular SF Symbols (~1.25 pt), slightly thicker for clarity at small sizes.
    static func checkmarkLineWidth(for size: CGFloat) -> CGFloat { max(1.25, size * 0.088) }

    var iconAlpha: CGFloat { iconView.alphaValue }
    var checkmarkProgress: CGFloat { checkmarkView.drawnFraction }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func symbolImage(_ name: String) -> NSImage? {
        Design.Icon.symbol(name, description: toolTip)?
            .withSymbolConfiguration(.init(pointSize: symbolSize, weight: symbolWeight, scale: symbolScale))
    }

    /// Internal icon does not intercept clicks; otherwise the card header treats the click as non-button and collapses the card.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point).map { _ in self }
    }
}

/// Checkmark drawn via stroke animation, with thickness and rounded caps matching SF Symbols checkmark; does not intercept clicks.
final class CheckmarkView: NSView {
    private let shape = CAShapeLayer()
    private var strokeColor = ThemePalette.system.accent

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shape.fillColor = nil
        shape.lineCap = .round
        shape.lineJoin = .round
        shape.strokeEnd = 0
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        shape.frame = bounds
        shape.path = Self.path(in: bounds)
    }

    /// Fraction drawn (0 hidden, 1 complete).
    var drawnFraction: CGFloat { shape.opacity == 0 ? 0 : shape.strokeEnd }

    /// With y pointing down: short left stroke down to the bottom vertex, then long stroke up-right to finish.
    static func path(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.54))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.41, y: rect.minY + rect.height * 0.76))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.84, y: rect.minY + rect.height * 0.25))
        return path
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateStrokeColor(strokeColor)
    }

    func updateStrokeColor(_ color: NSColor) {
        strokeColor = color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance { shape.strokeColor = color.cgColor }
        CATransaction.commit()
    }

    func draw(color: NSColor, lineWidth: CGFloat, duration: TimeInterval, delay: TimeInterval) {
        layoutSubtreeIfNeeded()
        shape.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateStrokeColor(color)
        shape.lineWidth = lineWidth
        shape.opacity = 1
        shape.strokeEnd = 1
        CATransaction.commit()
        guard duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.beginTime = CACurrentMediaTime() + delay
        animation.duration = duration
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        shape.add(animation, forKey: "draw")
    }

    func hide(fade duration: TimeInterval) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.shape.opacity == 0 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.shape.strokeEnd = 0
            CATransaction.commit()
        }
        shape.opacity = 0
        CATransaction.commit()
    }
}

/// Icon view supporting rotation and crossfade image replacement; does not intercept clicks.
/// Rotation is implemented by redrawing the rotated image while keeping the view stationary to avoid Auto Layout conflicts.
private final class RotatingIconView: NSImageView {
    /// Target angle.
    private(set) var rotationDegrees: CGFloat = 0
    /// Currently displayed angle; interpolated between start and target during animation.
    private(set) var displayedDegrees: CGFloat = 0
    private var baseImage: NSImage?
    private var rotationTimer: Timer?
    /// Target vertical flip state and current displayed vertical scale (1 for normal, -1 for vertically mirrored).
    private(set) var isMirrored = false
    private(set) var displayedScaleY: CGFloat = 1
    private var flipTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setImage(_ image: NSImage?, fade duration: TimeInterval) {
        if duration > 0, let layer {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = duration
            layer.add(transition, forKey: "fade")
        }
        baseImage = image
        render()
    }

    /// Rotates clockwise to the specified angle; animates frame by frame with ease-in-out when duration > 0.
    /// Does not interrupt an in-flight animation if the target is unchanged; continues from the current displayed angle when retargeted mid-flight.
    func setRotation(degrees: CGFloat, duration: TimeInterval) {
        guard degrees != rotationDegrees else { return }
        rotationTimer?.invalidate()
        rotationTimer = nil
        rotationDegrees = degrees
        let from = displayedDegrees
        guard duration > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            show(degrees: degrees)
            return
        }
        // When reversing mid-flight, remaining distance is shorter; scale duration proportionally to keep angular speed consistent.
        let scaled = duration * min(1, abs(degrees - from) / 90)
        let start = CACurrentMediaTime()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let progress = scaled > 0 ? min(1, (CACurrentMediaTime() - start) / scaled) : 1
                let eased = progress * progress * (3 - 2 * progress)
                self.show(degrees: from + (degrees - from) * eased)
                if progress >= 1 {
                    timer.invalidate()
                    self.rotationTimer = nil
                }
            }
        }
    }

    /// Flips over the horizontal axis to vertically mirrored (or back); when duration > 0, squashes and expands frame by frame with cosine like flipping a card.
    /// Continues from the current position if retargeted mid-flight.
    func setMirrored(_ mirrored: Bool, duration: TimeInterval) {
        guard mirrored != isMirrored else { return }
        flipTimer?.invalidate()
        flipTimer = nil
        isMirrored = mirrored
        let to: CGFloat = mirrored ? .pi : 0
        guard duration > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            displayedScaleY = cos(to)
            render()
            return
        }
        let from = acos(max(-1, min(1, displayedScaleY)))
        let scaled = duration * abs(to - from) / .pi
        let start = CACurrentMediaTime()
        flipTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let progress = scaled > 0 ? min(1, (CACurrentMediaTime() - start) / scaled) : 1
                let eased = progress * progress * (3 - 2 * progress)
                self.displayedScaleY = cos(from + (to - from) * eased)
                self.render()
                if progress >= 1 {
                    timer.invalidate()
                    self.flipTimer = nil
                }
            }
        }
    }

    private func show(degrees: CGFloat) {
        displayedDegrees = degrees
        render()
    }

    private func render() {
        image = Self.rotated(baseImage, degrees: displayedDegrees, scaleY: displayedScaleY)
    }

    /// Draws the rotated (and vertically scaled) image centered in a square canvas, preserving template mode for tinting.
    static func rotated(_ image: NSImage?, degrees: CGFloat, scaleY: CGFloat = 1) -> NSImage? {
        guard let image, degrees.truncatingRemainder(dividingBy: 360) != 0 || scaleY != 1 else { return image }
        let side = max(image.size.width, image.size.height)
        let canvas = NSSize(width: side, height: side)
        let result = NSImage(size: canvas, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: -degrees * .pi / 180)  // In unflipped coordinates, counterclockwise is positive
            context.scaleBy(x: 1, y: scaleY)
            image.draw(in: NSRect(x: -image.size.width / 2, y: -image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
            return true
        }
        result.isTemplate = image.isTemplate
        return result
    }
}
