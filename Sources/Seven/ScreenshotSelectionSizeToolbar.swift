import AppKit

/// 选区左上方的小型尺寸面板，只编辑输出宽高与比例。
@MainActor final class ScreenshotSelectionSizeToolbar: NSView, NSTextFieldDelegate, ThemeApplying {
    private let separator = NSTextField(labelWithString: "×")
    var onWidthChange: ((Int) -> Void)?
    var onHeightChange: ((Int) -> Void)?
    var onCornerChange: ((CGFloat) -> Void)?
    private let corner = ScreenshotValueSlider(value: 0, min: 0, max: 1)
    var onRatioChange: ((ScreenshotAspectRatio) -> Void)?
    private let widthField = ScreenshotSizeField()
    private let heightField = ScreenshotSizeField()
    private let ratioMenu = ScreenshotRatioMenu(frame: .zero, pullsDown: false)
    private let cornerIcon = NSImageView(image: Design.Icon.symbol("viewfinder", description: L10n.text("screenshotCornerRadius")) ?? NSImage())
    private var ratioWidth: NSLayoutConstraint?
    private var panels: [NSView] = []
    private var panelWidths: [NSLayoutConstraint] = []
    private var pixelSize = CGSize.zero
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        separator.font = Design.Text.body.nsFont
        for (index, field) in [widthField, heightField].enumerated() {
            let formatter = NumberFormatter(); formatter.allowsFloats = false; formatter.minimum = 1; formatter.usesGroupingSeparator = false
            field.formatter = formatter; field.font = Design.Text.body.nsFont
            field.alignment = .center; field.controlSize = .small
            field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
            field.focusRingType = .none
            field.delegate = self; field.target = self; field.action = #selector(commitSize(_:))
            field.tag = index
            field.setAccessibilityLabel(index == 0 ? L10n.text("screenshotWidthInPixels") : L10n.text("screenshotHeightInPixels"))
            field.toolTip = index == 0 ? L10n.text("widthInPixels") : L10n.text("heightInPixels")
            field.widthAnchor.constraint(equalToConstant: Design.ScreenshotEditor.sizeFieldWidth).isActive = true
            field.heightAnchor.constraint(equalToConstant: Design.ScreenshotEditor.sizeControlHeight).isActive = true
        }
        ratioMenu.addItems(withTitles: ScreenshotAspectRatio.allCases.map(\.title))
        ratioMenu.controlSize = .small; ratioMenu.font = Design.Text.body.nsFont; ratioMenu.isBordered = false
        (ratioMenu.cell as? NSPopUpButtonCell)?.usesItemFromMenu = false
        (ratioMenu.cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false
        ratioMenu.focusRingType = .none; ratioMenu.alignment = .left
        ratioWidth = ratioMenu.widthAnchor.constraint(equalToConstant: Design.ScreenshotEditor.sizeRatioMinimumWidth)
        ratioWidth?.isActive = true
        ratioMenu.target = self; ratioMenu.action = #selector(changeRatio)
        ratioMenu.setAccessibilityLabel(L10n.text("screenshotAspectRatio")); ratioMenu.toolTip = L10n.text("screenshotAspectRatio")

        cornerIcon.imageScaling = .scaleProportionallyDown
        corner.formatValue = { L10n.format("cornerRadiusPx", String(describing: Int($0.rounded()))) }
        corner.setAccessibilityLabel(L10n.text("screenshotCornerRadius")); corner.toolTip = L10n.text("cornerRadius0Px")
        corner.target = self; corner.action = #selector(changeCorner)
        corner.controlSize = .mini
        let divider = ScreenshotToolbarDivider(); divider.boxType = .separator
        let row = NSStackView(views: [widthField, separator, heightField, ratioMenu, divider, cornerIcon, corner])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = Design.Space.xs
        // 原生菜单自身带左侧留白，移到箭头右侧，使可见间距平衡。
        row.setCustomSpacing(0, after: heightField)
        row.setCustomSpacing(Design.Space.s, after: ratioMenu)
        NSLayoutConstraint.activate([
            cornerIcon.widthAnchor.constraint(equalToConstant: Design.ScreenshotEditor.sizeSymbolSize),
            cornerIcon.heightAnchor.constraint(equalToConstant: Design.ScreenshotEditor.sizeSymbolSize),
            corner.widthAnchor.constraint(equalToConstant: Design.ScreenshotEditor.sizeSliderWidth),
            corner.heightAnchor.constraint(equalToConstant: Design.ScreenshotEditor.sizeControlHeight),
            divider.widthAnchor.constraint(equalToConstant: Design.ScreenshotEditor.toolbarDividerWidth),
            divider.heightAnchor.constraint(equalToConstant: Design.ScreenshotEditor.sizeDividerHeight)
        ])
        panels = [surface(row)]
        let groups = NSStackView(views: panels)
        groups.orientation = .horizontal; groups.alignment = .centerY; groups.spacing = Design.Space.s
        groups.translatesAutoresizingMaskIntoConstraints = false; addSubview(groups)
        NSLayoutConstraint.activate([
            groups.leadingAnchor.constraint(equalTo: leadingAnchor), groups.trailingAnchor.constraint(equalTo: trailingAnchor),
            groups.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Design.ScreenshotEditor.sizeToolbarHeight)
        ])
        ThemeManager.shared.register(self)
    }

    func applyTheme(_ palette: ThemePalette) {
        separator.textColor = palette.ink
        for field in [widthField, heightField] { field.applyTheme(palette) }
        ratioMenu.applyTheme(palette)
        cornerIcon.contentTintColor = palette.ink
    }

    private func surface(_ content: NSView) -> NSView {
        let view = ScreenshotSizeSurface()
        view.wantsLayer = true; view.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(content)
        let width = view.widthAnchor.constraint(equalToConstant: content.fittingSize.width + Design.Space.xs * 2)
        width.isActive = true; panelWidths.append(width)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Space.xs),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Space.xs),
            content.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            view.heightAnchor.constraint(equalToConstant: Design.ScreenshotEditor.sizeToolbarHeight)
        ])
        return view
    }
    required init?(coder: NSCoder) { nil }
    func refreshInterfaceLanguage() {
        for (field, key) in [(widthField, "screenshotWidthInPixels"), (heightField, "screenshotHeightInPixels")] {
            let label = L10n.text(key)
            field.setAccessibilityLabel(label)
            field.toolTip = label
        }
        ratioMenu.setAccessibilityLabel(L10n.text("screenshotAspectRatio"))
        ratioMenu.toolTip = L10n.text("screenshotAspectRatio")
        for (item, ratio) in zip(ratioMenu.itemArray, ScreenshotAspectRatio.allCases) { item.title = ratio.title }
        if let ratio = ScreenshotAspectRatio.allCases.dropFirst(max(0, ratioMenu.indexOfSelectedItem)).first {
            updateRatio(ratio)
        }
        let label = L10n.text("screenshotCornerRadius")
        cornerIcon.image?.accessibilityDescription = label
        corner.setAccessibilityLabel(label)
        corner.toolTip = corner.formatValue(corner.doubleValue)
    }

    func update(size: CGSize, ratio: ScreenshotAspectRatio, cornerRadius: CGFloat) {
        pixelSize = size
        corner.maxValue = max(0, Double(min(size.width, size.height) / 2).rounded(.down))
        corner.doubleValue = min(max(0, Double(cornerRadius)), corner.maxValue)
        corner.toolTip = corner.formatValue(corner.doubleValue)
        widthField.stringValue = String(Int(size.width)); heightField.stringValue = String(Int(size.height))
        updateRatio(ratio)
    }
    private func updateRatio(_ ratio: ScreenshotAspectRatio) {
        let index = ScreenshotAspectRatio.allCases.firstIndex(of: ratio) ?? 0
        let title = ratio == .free ? "" : ratio.title
        if ratioMenu.indexOfSelectedItem != index || ratioMenu.ratioName != ratio.title || (ratioMenu.cell as? NSPopUpButtonCell)?.menuItem?.title != title {
            ratioMenu.selectItem(at: index)
            ratioMenu.ratioName = ratio.title
            ratioMenu.updateTitle(title)
        }
        let width = max(Design.ScreenshotEditor.sizeRatioMinimumWidth, ratioMenu.intrinsicContentSize.width)
        guard width != ratioWidth?.constant else { return }
        if let oldWidth = ratioWidth?.constant, let panelWidth = panelWidths.first { panelWidth.constant += width - oldWidth }
        ratioWidth?.constant = width
    }
    @objc private func commitSize(_ sender: NSTextField) {
        guard let value = Int(sender.stringValue.trimmingCharacters(in: .whitespaces)), value > 0 else {
            sender.stringValue = String(Int(sender === widthField ? pixelSize.width : pixelSize.height)); return
        }
        if sender === widthField { onWidthChange?(value) } else { onHeightChange?(value) }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField { commitSize(field) }
    }
    @objc private func changeRatio() {
        let index = ratioMenu.indexOfSelectedItem
        guard ScreenshotAspectRatio.allCases.indices.contains(index) else { return }
        onRatioChange?(ScreenshotAspectRatio.allCases[index])
    }
    @objc private func changeCorner() {
        corner.toolTip = corner.formatValue(corner.doubleValue)
        corner.updateValueCaption()
        onCornerChange?(CGFloat(corner.doubleValue.rounded()))
    }
}

private final class ScreenshotSizeSurface: ThemedDrawingView {
    override func draw(_ dirtyRect: NSRect) {
        theme.surfaceRaised.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Design.ScreenshotEditor.sizeToolbarRadius, yRadius: Design.ScreenshotEditor.sizeToolbarRadius).fill()
    }
}

private final class ScreenshotSizeField: NSTextField {
    private var palette = ThemePalette.system

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        textColor = palette.ink
        needsDisplay = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        cell = ScreenshotSizeFieldCell(textCell: "")
        isEditable = true; isSelectable = true
    }
    required init?(coder: NSCoder) { nil }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override func draw(_ dirtyRect: NSRect) {
        palette.screenshotSizeFieldFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Design.ScreenshotEditor.sizeFieldRadius, yRadius: Design.ScreenshotEditor.sizeFieldRadius).fill()
        super.draw(dirtyRect)
    }
}

private final class ScreenshotRatioMenu: NSPopUpButton, ThemeApplying {
    private var palette = ThemePalette.system

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        updateTitle(indexOfSelectedItem == 0 ? "" : ratioName)
    }

    func updateTitle(_ title: String) {
        let index = indexOfSelectedItem
        applyThemeToMenuTitle(palette, title: title)
        contentTintColor = palette.ink
        for (itemIndex, item) in itemArray.enumerated() { item.state = itemIndex == index ? .on : .off }
    }

    override var alignmentRectInsets: NSEdgeInsets {
        var insets = super.alignmentRectInsets
        insets.right += Design.ScreenshotEditor.sizeRatioTrailingInset
        return insets
    }
    var ratioName = ScreenshotAspectRatio.free.title
    override func accessibilityValue() -> Any? { ratioName }
}

/// 绘制与原生编辑共用居中的文字区域，避免无边框 cell 默认靠上绘制。
private final class ScreenshotSizeFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var text = super.drawingRect(forBounds: rect)
        let height = min(rect.height, cellSize(forBounds: rect).height)
        text.origin.y = rect.midY - height / 2
        text.size.height = height
        return text
    }
    override func select(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, start: start, length: length)
    }
    override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, event: event)
    }
}
