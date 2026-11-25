import AppKit

/// 根据实际的 AppKit 响应者绘制焦点环，即使用户尚未输入文字。
final class SettingsFieldFocusRing: NSView, ThemeApplying {
    private weak var editor: NSView?
    private var palette = ThemePalette.system
    private var firstResponderObservation: NSKeyValueObservation?
    private let autofocus: Bool
    private let nativeFocusRingType: NSFocusRingType

    init(editor: NSView, in container: NSView, autofocus: Bool = false) {
        self.editor = editor
        self.autofocus = autofocus
        nativeFocusRingType = editor.focusRingType
        super.init(frame: container.bounds)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(false)
        container.addSubview(self, positioned: .above, relativeTo: nil)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        firstResponderObservation = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateVisibility()
        guard let window else { return }
        firstResponderObservation = window.observe(\.firstResponder) { [weak self] _, _ in
            // 窗口切换响应者期间会先交接 field editor，等 AppKit 完成再读取。
            DispatchQueue.main.async { [weak self] in self?.updateVisibility() }
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowKeyStatusChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowKeyStatusChanged(_:)), name: NSWindow.didResignKeyNotification, object: window)
        if autofocus {
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, window === self.window, let editor else { return }
                window.makeFirstResponder(editor)
            }
        }
    }

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        editor?.focusRingType = palette.isSystem ? nativeFocusRingType : .none
        updateVisibility()
        needsDisplay = true
    }

    @objc private func windowKeyStatusChanged(_ notification: Notification) {
        updateVisibility()
    }

    private func updateVisibility() {
        guard !palette.isSystem, let editor, let window, window.isKeyWindow, let responder = window.firstResponder else {
            isHidden = true
            return
        }
        let field = editor as? NSTextField
        let acceptsFocus = field?.isEnabled ?? (editor as? NSTextView)?.isEditable ?? true
        isHidden = !acceptsFocus || !(responder === editor || responder === field?.currentEditor())
    }

    override func draw(_ dirtyRect: NSRect) {
        let width = Design.Settings.focusRingWidth
        let inset = width / 2
        let radius = max(0, (editor is NSSearchField ? bounds.height / 2 : Design.Radius.control) - inset)
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
        outline.lineWidth = width
        palette.focusStroke.setStroke()
        outline.stroke()
    }
}
