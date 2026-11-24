import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let permissionGuide: PermissionGuide
    private let flow: OnboardingFlow
    private let openInput: () -> Void
    private let didClose: () -> Void

    init(flow: OnboardingFlow, window: NSWindow, permissionGuide: PermissionGuide,
         openInput: @escaping () -> Void, didClose: @escaping () -> Void) {
        self.flow = flow
        self.permissionGuide = permissionGuide
        self.openInput = openInput
        self.didClose = didClose
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    convenience init(flow: OnboardingFlow, launchAtLogin: LaunchAtLoginController,
                     openInput: @escaping () -> Void, didClose: @escaping () -> Void) {
        let window = Self.makeWindow()
        self.init(flow: flow, window: window, permissionGuide: .shared,
                  openInput: openInput, didClose: didClose)
        refreshInterfaceLanguage()
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.acceptsMouseMovedEvents = true
        let view = OnboardingView(
            launchAtLogin: launchAtLogin,
            flow: flow,
            authorize: { [weak self] in self?.authorize($0) },
            start: { [weak self] in self?.startUsing() }
        )
        let hostingView = NSHostingView(rootView: ThemedContent(content: view))
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    static func makeWindow() -> NSWindow {
        OnboardingWindow(
            contentRect: NSRect(origin: .zero, size: Design.Onboarding.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshInterfaceLanguage() {
        window?.title = L10n.text("onboarding.welcome")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 关闭按钮和 Esc 走原生 performClose。退出或系统重启应用不在这里登记完成。
        flow.finish(.dismiss, close: {}, openInput: openInput)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        permissionGuide.close(ifOwnedBy: self)
        didClose()
    }

    func authorize(_ permission: PermissionGuide.Permission) {
        permissionGuide.authorize(permission, owner: self)
    }

    func startUsing() {
        flow.finish(.start, close: { window?.close() }, openInput: openInput)
    }
}

private final class OnboardingWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
            performClose(nil)
            return
        }
        super.sendEvent(event)
    }
}
