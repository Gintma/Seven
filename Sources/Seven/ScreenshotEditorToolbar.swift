import AppKit

/// 主栏只放工具/动作；第二张浮动条只显示当前工具的选项。
final class ScreenshotEditorToolbar: NSStackView {
    let primary = NSStackView()
    let options = NSStackView()
    var hasOptions = true { didSet { arrangedSubviews.last?.isHidden = !hasOptions } }
    private var primaryWidth: NSLayoutConstraint?
    private var optionsWidth: NSLayoutConstraint?

    init(compactStatus: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        orientation = .vertical
        alignment = .leading
        spacing = Design.Space.s
        primary.orientation = .horizontal
        primary.alignment = .centerY
        primary.spacing = Design.ScreenshotEditor.toolbarItemSpacing
        options.orientation = .horizontal
        options.alignment = .centerY
        options.spacing = Design.ScreenshotEditor.toolbarOptionsSpacing
        let primaryBar = Self.bar(containing: primary), optionsBar = Self.bar(containing: options, compact: compactStatus)
        addArrangedSubview(primaryBar); addArrangedSubview(optionsBar)
        optionsBar.heightAnchor.constraint(equalToConstant: compactStatus ? Design.ScreenshotEditor.sizeToolbarHeight : Design.ScreenshotEditor.toolbarOptionsHeight).isActive = true
        primaryWidth = primaryBar.widthAnchor.constraint(equalToConstant: 1)
        optionsWidth = optionsBar.widthAnchor.constraint(equalToConstant: 1)
        primaryWidth?.isActive = true; optionsWidth?.isActive = true
    }
    required init?(coder: NSCoder) { nil }

    private static func bar(containing content: NSStackView, compact: Bool = false) -> NSView {
        let bar = ScreenshotToolbarSurface()
        if compact { bar.cornerRadius = Design.ScreenshotEditor.sizeToolbarRadius }
        bar.wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(content)
        let inset = Design.ScreenshotEditor.toolbarBarInset
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -inset),
            content.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        if !compact {
            content.topAnchor.constraint(equalTo: bar.topAnchor, constant: inset).isActive = true
            content.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -inset).isActive = true
        }
        return bar
    }

    func fitVisibleContent(maximumOptionsWidth: CGFloat? = nil) {
        var seen=false,pending:NSBox?
        for view in primary.arrangedSubviews {
            if let box=view as? NSBox {box.isHidden=true;pending=box}
            else if !view.isHidden {if seen {pending?.isHidden=false};pending=nil;seen=true}
        }
        primaryWidth?.constant = primary.fittingSize.width + Design.ScreenshotEditor.toolbarBarInset * 2
        let target = options.fittingSize.width + Design.ScreenshotEditor.toolbarBarInset * 2
        optionsWidth?.constant = min(target, maximumOptionsWidth ?? target)
        layoutSubtreeIfNeeded()
        needsLayout = true
    }

    func addDivider() {
        let divider = ScreenshotToolbarDivider()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: Design.ScreenshotEditor.toolbarDividerWidth).isActive = true
        divider.heightAnchor.constraint(equalToConstant: Design.ScreenshotEditor.toolbarDividerHeight).isActive = true
        primary.addArrangedSubview(divider)
        primary.setCustomSpacing(Design.Space.s, after: divider)
    }
}

class ScreenshotToolbarButton: NSButton, ThemeApplying {
    private var palette = ThemePalette.system
    var isDragHandle = false { didSet { updateTint() } }

    override var state: NSControl.StateValue { didSet { updateTint() } }

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        updateTint()
    }

    private func updateTint() {
        contentTintColor = isDragHandle ? palette.inkSecondary : (state == .on ? palette.accent : palette.ink)
        needsDisplay = true
    }

    // 工具图标没有系统按钮边框；不能让原生对齐边距把正方形 frame 撑高。
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    init(symbol: String, title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        image = Design.Icon.symbol(symbol, description: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Design.ScreenshotEditor.toolbarSymbolSize, weight: .regular))
        imagePosition = .imageOnly
        isBordered = false
        ThemeManager.shared.register(self)
        self.target = target
        self.action = action
        toolTip = title
        setAccessibilityLabel(title)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Design.ScreenshotEditor.toolbarButtonSize),
            heightAnchor.constraint(equalToConstant: Design.ScreenshotEditor.toolbarButtonSize)
        ])
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            palette.toolbarSelectionFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Design.ScreenshotEditor.toolbarButtonRadius, yRadius: Design.ScreenshotEditor.toolbarButtonRadius).fill()
        }
        super.draw(dirtyRect)
    }
}

final class ScreenshotToolbarDragButton: ScreenshotToolbarButton {
    var onDragBegan: (() -> Void)?
    var onDrag: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?
    private var origin = CGPoint.zero
    init() {
        // 打包后的 App 使用 SVG 模板资源，命令行与测试构建使用原生占位图。
        super.init(symbol: "circle.grid.3x3.fill", title: L10n.text("dragToolbar"), target: nil, action: nil)
        if let asset = NSImage(named: NSImage.Name(Design.Icon.screenshotDrag)), let icon = asset.copy() as? NSImage {
            let scale = Design.ScreenshotEditor.toolbarSymbolSize / max(icon.size.width, icon.size.height)
            icon.size = CGSize(width: icon.size.width * scale, height: icon.size.height * scale)
            icon.isTemplate = true
            image = icon
        }
        isDragHandle = true
    }
    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        origin = window.convertPoint(toScreen: event.locationInWindow)
        onDragBegan?(); NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        NSCursor.closedHand.set()
        onDrag?(CGSize(width: point.x - origin.x, height: point.y - origin.y))
    }
    override func mouseUp(with event: NSEvent) { onDragEnded?(); NSCursor.arrow.set() }
}

private final class ScreenshotToolbarSurface: ThemedDrawingView {
    var cornerRadius = Design.ScreenshotEditor.toolbarRadius
    override func draw(_ dirtyRect: NSRect) {
        theme.surfaceRaised.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
}

final class ScreenshotValueSlider: NSSlider, ThemeApplying {
    private var palette = ThemePalette.system
    var onEditingBegan: (() -> Void)?
    var onEditingEnded: (() -> Void)?
    var formatValue: (Double) -> String = { String(Int($0)) }
    private var valuePopover: NSPopover?
    private var valueLabel: NSTextField?
    init(value: Double, min: Double, max: Double) {
        super.init(frame: .zero)
        cell = ScreenshotSliderCell()
        minValue = min; maxValue = max; doubleValue = value
        isContinuous = true
        ThemeManager.shared.register(self)
    }
    required init?(coder: NSCoder) { nil }
    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        (cell as? ScreenshotSliderCell)?.palette = palette
        (valuePopover?.contentViewController?.view as? ScreenshotValueBubble)?.applyTheme(palette)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onEditingBegan?()
        defer { onEditingEnded?() }
        let content = ScreenshotValueBubble(text: formatValue(doubleValue))
        content.applyTheme(palette)
        let label = content.label
        let controller = NSViewController(); controller.view = content
        let popover = NSPopover(); popover.animates = false
        popover.contentViewController = controller
        popover.contentSize = content.fittingSize
        valuePopover = popover; valueLabel = label
        popover.show(relativeTo: (cell as? NSSliderCell)?.knobRect(flipped: isFlipped) ?? bounds, of: self, preferredEdge: .maxY)
        defer { popover.close(); valuePopover = nil; valueLabel = nil }
        super.mouseDown(with: event)
    }
    func updateValueCaption() {
        valueLabel?.stringValue = formatValue(doubleValue)
        if let content = valuePopover?.contentViewController?.view { valuePopover?.contentSize = content.fittingSize }
        if let rect = (cell as? NSSliderCell)?.knobRect(flipped: isFlipped) { valuePopover?.positioningRect = rect }
    }
}

final class ScreenshotValueBubble: NSView {
    let label: NSTextField
    private var palette = ThemePalette.system

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        label.textColor = palette.isSystem ? nil : palette.ink
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if !palette.isSystem {
            palette.surfaceRaised.setFill()
            bounds.fill()
        }
        super.draw(dirtyRect)
    }

    init(text: String) {
        label = NSTextField(labelWithString: text)
        label.font = Design.Text.settingsRow.nsFont
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.ScreenshotEditor.valueBubbleHorizontalInset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.ScreenshotEditor.valueBubbleHorizontalInset),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Design.ScreenshotEditor.valueBubbleVerticalInset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.ScreenshotEditor.valueBubbleVerticalInset)
        ])
    }
    required init?(coder: NSCoder) { nil }
}

@MainActor enum ScreenshotToolbarSymbols {
    static func arrow(_ style: ScreenshotArrowStyle) -> NSImage? {
        let symbol = Design.Icon.symbol(style.symbol, description: style.title)?
            .withSymbolConfiguration(.init(pointSize: Design.Segmented.iconSize, weight: style == .solid ? .bold : .regular))
        guard style != .openHead, let symbol else { return symbol }
        // 旋转官方向上箭头，字形仍来自 SF Symbols。
        return NSImage(size: symbol.size, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY); transform.rotate(byDegrees: -45)
            transform.translateX(by: -rect.midX, yBy: -rect.midY); transform.concat()
            symbol.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }
    static func text(_ style: ScreenshotEditorTextStyle) -> NSImage {
        // withLocale 固定官方拉丁 Aa 表示，不随中文系统切换为“字”。
        NSImage(systemSymbolName: "textformat", accessibilityDescription: style.title)?
            .withLocale(Locale(identifier: "en")) ?? NSImage()
    }
    static func shape(_ mode: ScreenshotShapeMode, ellipse: Bool = false) -> NSImage {
        let symbols = ellipse ? ["circle", "circle.lefthalf.filled", "circle.fill"] : ["rectangle", "rectangle.lefthalf.filled", "rectangle.fill"]
        return NSImage(systemSymbolName: symbols[mode.rawValue], accessibilityDescription: mode.title) ?? NSImage()
    }
    static func line(dashed: Bool) -> NSImage {
        NSImage(systemSymbolName: dashed ? "ellipsis" : "minus", accessibilityDescription: dashed ? L10n.text("dashed") : L10n.text("solid")) ?? NSImage()
    }

}

final class ScreenshotEditorToolsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class ScreenshotSliderCell: NSSliderCell {
    var palette = ThemePalette.system

    override func drawKnob(_ knobRect: NSRect) {
        if palette.isSystem {
            super.drawKnob(knobRect)
        } else {
            let knob = NSBezierPath(ovalIn: knobRect.insetBy(dx: 1, dy: 1))
            palette.surfaceRaised.setFill()
            knob.fill()
            (isEnabled ? palette.focusStroke : palette.separator).setStroke()
            knob.lineWidth = 1
            knob.stroke()
        }
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let height = Design.ScreenshotEditor.toolbarTrackHeight
        let track = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        palette.separator.setFill()
        NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2).fill()
        let end = min(track.maxX, max(track.minX, knobRect(flipped: flipped).midX))
        palette.sliderAccent.setFill()
        NSBezierPath(roundedRect: CGRect(x: track.minX, y: track.minY, width: end - track.minX, height: height), xRadius: height / 2, yRadius: height / 2).fill()
    }
}


final class ScreenshotToolbarDivider: NSBox, ThemeApplying {
    private var palette = ThemePalette.system

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { ThemeManager.shared.register(self) }
    }

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if palette.isSystem {
            super.draw(dirtyRect)
        } else {
            let thickness = Design.ScreenshotEditor.toolbarDividerWidth
            let line = bounds.width < bounds.height
                ? NSRect(x: bounds.midX - thickness / 2, y: bounds.minY, width: thickness, height: bounds.height)
                : NSRect(x: bounds.minX, y: bounds.midY - thickness / 2, width: bounds.width, height: thickness)
            palette.separator.setFill()
            line.fill()
        }
    }
}
