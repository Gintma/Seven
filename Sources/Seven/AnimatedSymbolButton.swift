import AppKit

/// 带操作反馈的按钮：图标淡入淡出替换、绕中心旋转、弹跳与晃动、画出对勾确认。
/// 图标由内部视图绘制；点击始终由按钮本身处理。
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
    /// 确认动画：图标淡出 → 对勾画出。
    static let iconOutDuration = Design.Motion.fast
    static let checkmarkDrawDuration = Design.Motion.standard
    static let rotationDuration = Design.Motion.standard

    /// 外形偏高的符号（如上下叠放的 doc.on.doc）可用 `.small` 缩放配合 `.medium` 字重，
    /// 使视觉大小与线宽和相邻图标一致。
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

    /// 基类在初始化时也会调用；此时内部图标视图尚未加入，忽略即可。
    override func setSymbol(_ name: String, size: CGFloat = 16) {
        setSymbol(name, animated: false)
    }

    /// 淡入淡出替换图标：不缩放、不位移。
    func setSymbol(_ name: String, animated: Bool) {
        guard iconView.superview != nil else { return }
        guard name != symbolName || iconView.image == nil else { return }
        symbolName = name
        iconView.setImage(symbolImage(name), fade: animated ? Self.fadeDuration : 0)
    }

    /// 绕图标中心旋转到指定角度（顺时针为正）。
    func setRotation(degrees: CGFloat, animated: Bool) {
        iconView.setRotation(degrees: degrees, duration: animated ? Self.rotationDuration : 0)
    }

    /// 上下翻面（例如 ⇌ 翻成 ⇋），翻面后保持；`standard` 时长。
    func setMirrored(_ mirrored: Bool, animated: Bool) {
        iconView.setMirrored(mirrored, duration: animated ? Self.rotationDuration : 0)
    }

    var isMirrored: Bool { iconView.isMirrored }
    var displayedScaleY: CGFloat { iconView.displayedScaleY }
    var displayedRotationDegrees: CGFloat { iconView.displayedDegrees }

    /// 左右晃动（macOS 15 起提供）；更早的系统不晃动。
    func wiggle() {
        guard !Self.reduceMotion else { return }
        if #available(macOS 15.0, *) {
            iconView.addSymbolEffect(.wiggle)
        }
    }

    /// 操作成功的反馈：图标淡出，强调色对勾随即画出；片刻后对勾淡出、图标淡回。
    /// 确认期间再次点击只重新计时，不重画对勾。
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

    /// 与 16 pt 常规字重 SF Symbols 的线宽（约 1.25 pt）相近，略加粗以保证小尺寸下清晰。
    static func checkmarkLineWidth(for size: CGFloat) -> CGFloat { max(1.25, size * 0.088) }

    var iconAlpha: CGFloat { iconView.alphaValue }
    var checkmarkProgress: CGFloat { checkmarkView.drawnFraction }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func symbolImage(_ name: String) -> NSImage? {
        Design.Icon.symbol(name, description: toolTip)?
            .withSymbolConfiguration(.init(pointSize: symbolSize, weight: symbolWeight, scale: symbolScale))
    }

    /// 内部图标不接收点击：否则卡片标题栏会把点击判定为“不是按钮”而收起卡片。
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point).map { _ in self }
    }
}

/// 用描边动画“画”出的对勾，粗细与圆角线头对齐 SF Symbols 的 checkmark；不接收点击。
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

    /// 已画出的比例（0 未显示，1 完整）。
    var drawnFraction: CGFloat { shape.opacity == 0 ? 0 : shape.strokeEnd }

    /// 坐标 y 向下：左段短笔画落到底点，再向右上长笔画收尾。
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

/// 可旋转、可淡入淡出换图的图标视图；不接收点击。
/// 旋转通过重绘旋转后的图像实现，视图本身不动，避免与自动布局冲突。
private final class RotatingIconView: NSImageView {
    /// 目标角度。
    private(set) var rotationDegrees: CGFloat = 0
    /// 当前实际显示的角度；动画进行中介于起点与目标之间。
    private(set) var displayedDegrees: CGFloat = 0
    private var baseImage: NSImage?
    private var rotationTimer: Timer?
    /// 上下翻面的目标状态，以及当前显示的纵向缩放（1 为原样，-1 为上下镜像）。
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

    /// 顺时针旋转到指定角度；duration > 0 时以缓入缓出逐帧过渡。
    /// 目标未变时不打断进行中的动画；中途改变目标时从当前显示角度继续。
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
        // 中途反向时剩余距离较短，按比例缩短时长，保持转速一致。
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

    /// 绕水平轴翻面到上下镜像（或翻回）；duration > 0 时按余弦逐帧压扁再展开，像翻卡片。
    /// 中途改变目标时从当前位置继续。
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

    /// 在正方形画布中绕中心绘制旋转（及纵向缩放）后的图像；保留模板属性以继续使用着色。
    static func rotated(_ image: NSImage?, degrees: CGFloat, scaleY: CGFloat = 1) -> NSImage? {
        guard let image, degrees.truncatingRemainder(dividingBy: 360) != 0 || scaleY != 1 else { return image }
        let side = max(image.size.width, image.size.height)
        let canvas = NSSize(width: side, height: side)
        let result = NSImage(size: canvas, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: -degrees * .pi / 180)  // 未翻转坐标中逆时针为正
            context.scaleBy(x: 1, y: scaleY)
            image.draw(in: NSRect(x: -image.size.width / 2, y: -image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
            return true
        }
        result.isTemplate = image.isTemplate
        return result
    }
}
