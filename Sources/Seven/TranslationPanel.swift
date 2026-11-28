import AppKit

final class TranslationPanel: NSPanel {
    private let model: TranslationModel

    init(model: TranslationModel) {
        self.model = model
        super.init(contentRect: NSRect(x: 0, y: 0, width: TranslationPanelSize.defaultWidth, height: 440),
                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }

    func prepareForInputPresentation() {
        if !isVisible { model.clearPanelContentIfEnabled() }
    }

    func dismiss() {
        guard isVisible else { return }
        orderOut(nil)
        model.clearPanelContentIfEnabled()
    }

    override func close() {
        super.close()
        model.clearPanelContentIfEnabled()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Panel height tracks content, so zooming is meaningless; also blocks double-clicking the title bar from zooming.
    override func zoom(_ sender: Any?) {}

    /// Keep only the close button: minimize is unsupported, and zoom makes no sense for a content-sized panel.
    /// The close button is primarily for the pinned state, where clicking outside does not hide the panel.
    func configureWindowButtons() {
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        standardWindowButton(.closeButton)?.isHidden = false
    }
}
