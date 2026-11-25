import AppKit

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 带底色、描边与圆角的区块。颜色在绘制时按当前外观解析，切换浅色与深色时自动更新。
class LayerBackedView: FlippedView {
    var fillColor: NSColor = ThemePalette.clear { didSet { needsDisplay = true } }
    var strokeColor: NSColor = ThemePalette.clear { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    /// 外观切换后调用，供需要自行着色的子视图更新颜色。
    var onEffectiveAppearanceChange: (() -> Void)?

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        onEffectiveAppearanceChange?()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func updateLayer() {
        var fill: CGColor?
        var stroke: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = fillColor.cgColor
            stroke = strokeColor.cgColor
        }
        layer?.backgroundColor = fill
        layer?.borderColor = stroke
        layer?.borderWidth = strokeColor == ThemePalette.clear ? 0 : 1
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
    }
}

extension NSStackView {
    func removeAllArrangedSubviews() {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

extension NSTextField {
    static func wrappingLabel(
        _ value: String,
        font: NSFont = Design.Text.body.nsFont,
        color: NSColor = ThemePalette.system.ink
    ) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = font
        field.textColor = color
        field.isSelectable = true
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
}

extension NSButton {
    func updateLocalizedLabel(_ label: String, toolTip: String? = nil) {
        self.toolTip = toolTip ?? label
        setAccessibilityLabel(label)
        image?.accessibilityDescription = label
    }
}


extension NSButton {
    /// 原生按钮文字在自定义色板下使用同一前景色。
    func applyTheme(_ palette: ThemePalette, title: String) {
        if palette.isSystem {
            self.title = title
        } else {
            attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: palette.ink])
        }
    }
}

extension NSTextView {
    func applyThemeSelection(_ palette: ThemePalette) {
        if palette.isSystem {
            selectedTextAttributes = ThemePalette.nativeTextSelection
            insertionPointColor = ThemePalette.nativeInsertionPoint
        } else {
            selectedTextAttributes = [.backgroundColor: palette.selectionFill, .foregroundColor: palette.ink]
            insertionPointColor = palette.accent
        }
    }
}

/// 绘制型视图共用同一套失效机制。颜色留在 AppKit 绘制环境内解析。
class ThemedDrawingView: NSView, ThemeApplying {
    private(set) var theme = ThemePalette.system

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { ThemeManager.shared.register(self) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func applyTheme(_ palette: ThemePalette) {
        theme = palette
        needsDisplay = true
    }
}

extension NSTextField {
    func applyTheme(_ palette: ThemePalette, placeholder: String) {
        textColor = palette.isSystem ? ThemePalette.nativeControlInk : palette.ink
        backgroundColor = palette.surfaceInset
        if palette.isSystem {
            placeholderString = placeholder
        } else {
            placeholderAttributedString = NSAttributedString(
                string: placeholder, attributes: [.foregroundColor: palette.placeholder]
            )
        }
        (currentEditor() as? NSTextView)?.applyThemeSelection(palette)
    }
}

extension NSPopUpButton {
    func applyThemeToMenuTitle(_ palette: ThemePalette, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if !palette.isSystem {
            item.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: palette.ink])
        }
        (cell as? NSPopUpButtonCell)?.menuItem = item
        contentTintColor = palette.isSystem ? nil : palette.ink
        invalidateIntrinsicContentSize()
    }
}

class ThemedTableRow: NSTableRowView {
    let palette: ThemePalette

    init(palette: ThemePalette) {
        self.palette = palette
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { palette.isSystem ? super.interiorBackgroundStyle : .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        if palette.isSystem {
            super.drawSelection(in: dirtyRect)
        } else {
            let inset = usesInsetSelection
            let rect = inset ? bounds.insetBy(dx: Design.Layout.cardInset, dy: 0) : bounds
            guard !rect.isEmpty else { return }
            (inset ? palette.sidebarSelectionFill : palette.selectionFill).setFill()
            NSBezierPath(roundedRect: rect, xRadius: Design.Radius.control, yRadius: Design.Radius.control).fill()
        }
    }

    private var usesInsetSelection: Bool {
        var ancestor = superview
        while let view = ancestor {
            if let table = view as? NSTableView {
                return table.effectiveStyle == .inset || table.effectiveStyle == .sourceList
            }
            ancestor = view.superview
        }
        return false
    }
}
