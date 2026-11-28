import AppKit
import SwiftUI

/// Never activates the source app or displays source/translated text; stays anchored for the session while only the status pill width changes.
@MainActor
final class InputReplacementHUD: ThemeApplying {
    private var palette = ThemePalette.system
    let panel: NSPanel
    private let mouseLocation: () -> NSPoint
    private let root = InputReplacementSurface()
    private let label = ShimmerStatusLabel(frame: .zero)
    private let spinner = SolvingOrbView(frame: .zero)
    private let icon = NSImageView()
    private let dismissButton = NSButton()
    private var action: (() -> Void)?
    private var bridge: NSView?
    private var origin: NSPoint?
    private var loading = false
    private var message = LocalizedMessage.key("translating")
    private var explanation = LocalizedMessage.key("cancelTranslation")
    private var serviceHint: LocalizedMessage?

    init(mouseLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation }) {
        self.mouseLocation = mouseLocation
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = ThemePalette.clear
        panel.hasShadow = false
        panel.contentView = root
        label.font = Design.Text.body.nsFont
        label.lineBreakMode = .byTruncatingTail
        spinner.onFrame = { [weak self] in self?.label.needsDisplay = true }
        spinner.onMotionChange = { [weak self] in self?.label.refreshShimmer() }
        dismissButton.image = Design.Icon.symbol("xmark", description: L10n.text("cancel"))
        dismissButton.isBordered = false
        dismissButton.imagePosition = .imageOnly
        dismissButton.target = self
        dismissButton.action = #selector(dismiss)
        [label, spinner, icon, dismissButton].forEach(root.addSubview)
        ThemeManager.shared.register(self)
    }

    func setAnchor(_ anchor: NSPoint? = nil) {
        origin = anchor ?? mouseLocation()
    }

    func begin(anchor: NSPoint?, cancel: @escaping () -> Void) {
        setAnchor(anchor)
        action = cancel
        loading = true
        message = .key("translating")
        explanation = .key("cancelTranslation")
        serviceHint = nil
        render(dismissible: true)
    }

    func setServiceHint(_ title: String) {
        serviceHint = .key("translatingWith", .text(title))
        label.toolTip = serviceHint?.text
    }

    /// Keeps the current visual state during native writeback and only disables cancellation to avoid flashing a brief intermediate state.
    func prepareForWrite() {
        action = nil
        dismissButton.isEnabled = false
        dismissButton.toolTip = nil
    }

    func showFailure(_ message: LocalizedMessage, detail: LocalizedMessage) {
        action = nil
        if origin == nil { origin = mouseLocation() }
        loading = false
        self.message = message
        explanation = detail
        serviceHint = nil
        detachBridge()
        render(dismissible: false)
    }

    func refreshInterfaceLanguage() {
        guard panel.isVisible else { return }
        let wasEnabled = dismissButton.isEnabled
        render(dismissible: !dismissButton.isHidden)
        dismissButton.isEnabled = wasEnabled
        if !wasEnabled { dismissButton.toolTip = nil }
    }

    private func render(dismissible: Bool) {
        apply(message.text, dismissible: dismissible)
        let text = explanation.text
        label.toolTip = serviceHint?.text ?? text
        icon.toolTip = text
        root.toolTip = text
        label.setAccessibilityHelp(text)
    }

    private func apply(_ message: String, dismissible: Bool) {
        label.stringValue = message
        label.setLoading(loading)
        let height = Design.ReplacementHUD.height
        let glyph = Design.ReplacementHUD.orbSize
        let inset = Design.Space.m
        let gap = Design.Space.s
        let trailing = dismissible ? height : inset
        let measured = (message as NSString).size(withAttributes: [.font: Design.Text.body.nsFont]).width
        let width = min(Design.ReplacementHUD.maximumWidth, inset + glyph + gap + measured + gap + trailing)
        let available = NSScreen.screens.first { NSMouseInRect(origin ?? mouseLocation(), $0.frame, false) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let anchor = origin ?? mouseLocation()
        let x = min(max(available.minX + gap, anchor.x), available.maxX - width - gap)
        let y = min(max(available.minY + gap, anchor.y), available.maxY - height - gap)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        root.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let iconRect = NSRect(x: inset, y: (height - glyph) / 2, width: glyph, height: glyph)
        spinner.frame = iconRect
        spinner.isHidden = !loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        icon.frame = iconRect
        icon.isHidden = loading
        icon.image = Design.Icon.symbol("exclamationmark.circle", description: L10n.text("notReplaced"))
        label.frame = NSRect(x: inset + glyph + gap, y: (height - label.intrinsicContentSize.height) / 2,
                             width: max(0, width - inset - glyph - gap - trailing), height: label.intrinsicContentSize.height)
        dismissButton.frame = NSRect(x: width - height, y: 0, width: height, height: height)
        dismissButton.isHidden = !dismissible
        dismissButton.isEnabled = true
        dismissButton.toolTip = loading ? L10n.text("cancelTranslation2") : "关闭提示"
        dismissButton.setAccessibilityLabel(loading ? L10n.text("cancelTranslation2") : "关闭提示")
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    @available(macOS 15.0, *)
    func installBridge(model: TranslationModel) {
        let host = NSHostingView(rootView: AppleTranslationBridgeRoot(model: model))
        host.frame = .zero
        root.addSubview(host)
        bridge = host
    }

    func close() {
        spinner.stopAnimation(nil)
        label.setLoading(false)
        panel.orderOut(nil)
        action = nil
        detachBridge()
    }

    private func detachBridge() {
        bridge?.removeFromSuperview()
        bridge = nil
    }

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        root.applyTheme(palette)
        label.applyTheme(palette)
        spinner.applyTheme(palette)
        updateColors()
    }

    private func updateColors() {
        dismissButton.contentTintColor = palette.hudSecondary
        icon.contentTintColor = palette.hudSecondary
        label.needsDisplay = true
        spinner.needsDisplay = true
    }

    @objc private func dismiss() { action?() }
}

/// Resolves both solid surface and hairline border against the effective appearance; never samples the desktop or underlying windows.
@MainActor
final class InputReplacementSurface: ThemedDrawingView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = theme.hudBackground.cgColor
            layer?.borderColor = theme.hudBorder.cgColor
        }
        layer?.borderWidth = Design.ReplacementHUD.borderWidth
        layer?.cornerRadius = Design.ReplacementHUD.cornerRadius
        layer?.masksToBounds = true
    }
}
