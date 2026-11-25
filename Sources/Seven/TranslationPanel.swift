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

    /// 浮窗高度随内容变化，缩放没有意义；同时屏蔽双击标题栏触发的缩放。
    override func zoom(_ sender: Any?) {}

    /// 只保留关闭按钮：最小化本就不可用，缩放对随内容变高的浮窗没有意义。
    /// 关闭按钮主要服务于钉住状态（此时点击外部不会隐藏浮窗）。
    func configureWindowButtons() {
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        standardWindowButton(.closeButton)?.isHidden = false
    }
}
