import AppKit

final class TranslationPanel: NSPanel {
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
