import AppKit
import SwiftUI

/// Both the red close button and ⌘W go through performClose; after interception, the save/discard action re-initiates closing.
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
