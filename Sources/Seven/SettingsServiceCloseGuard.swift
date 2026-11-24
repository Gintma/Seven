import AppKit
import SwiftUI

/// 红色关闭按钮与 ⌘W 共用 performClose；拦截后由保存/放弃动作重新发起关闭。
final class SettingsCloseConfirmingWindow: NSWindow {
    var permitsClose: (() -> Bool)?
    var onClose: (() -> Void)?

    override func performClose(_ sender: Any?) {
        guard permitsClose?() ?? true else { return }
        super.performClose(sender)
    }
}

struct SettingsServiceCloseGuard: NSViewRepresentable {
    let permitsClose: (NSWindow) -> Bool
    let onClose: () -> Void

    func makeNSView(context: Context) -> SettingsServiceCloseGuardView {
        SettingsServiceCloseGuardView()
    }

    func updateNSView(_ view: SettingsServiceCloseGuardView, context: Context) {
        view.permitsClose = permitsClose
        view.onClose = onClose
        view.install()
    }

    static func dismantleNSView(_ view: SettingsServiceCloseGuardView, coordinator: ()) {
        (view.window as? SettingsCloseConfirmingWindow)?.permitsClose = nil
        (view.window as? SettingsCloseConfirmingWindow)?.onClose = nil
    }
}

final class SettingsServiceCloseGuardView: NSView {
    var permitsClose: ((NSWindow) -> Bool)?
    var onClose: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        install()
    }

    func install() {
        guard let window = window as? SettingsCloseConfirmingWindow else { return }
        window.permitsClose = { [weak self, weak window] in
            guard let self, let window else { return true }
            return self.permitsClose?(window) ?? true
        }
        window.onClose = { [weak self] in self?.onClose?() }
    }
}
