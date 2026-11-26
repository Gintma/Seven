import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var makeWindow: (() -> NSWindow)?
    private let sectionRequests = CurrentValueSubject<SettingsSection?, Never>(nil)
    private let launchAtLogin: LaunchAtLoginController

    init(
        model: TranslationModel,
        inputHotKeyManager: HotKeyManager,
        replacementHotKeyManager: HotKeyManager,
        hotKeyManager: HotKeyManager,
        screenshotHotKeyManager: HotKeyManager,
        pinVisibilityHotKeyManager: HotKeyManager, clipboardPinHotKeyManager: HotKeyManager,
        ocrShortcuts:OCRShortcuts? = nil,
        imageEntryShortcuts:ImageEntryShortcuts? = nil,
        closePinHotKeyManager:HotKeyManager? = nil,closeAllPinsHotKeyManager:HotKeyManager? = nil,
        regionCaptureHotKeyManager:HotKeyManager? = nil,fullCaptureHotKeyManager:HotKeyManager? = nil,previousCaptureHotKeyManager:HotKeyManager? = nil,
        launchAtLogin: LaunchAtLoginController,
        history: HistoryStore,
        dictionaryManager: ECDictionaryManager,
        diagnostics: DiagnosticLogging,
        updater: AppUpdater
    ) {
        self.launchAtLogin = launchAtLogin
        makeWindow = { [sectionRequests] in
            let window = SettingsCloseConfirmingWindow(
                contentRect: NSRect(x: 0, y: 0, width: Design.Settings.windowWidth, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = L10n.text("sevenSettings")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: Design.Settings.windowWidth, height: Design.Settings.minimumHeight)
            window.contentMaxSize = NSSize(width: Design.Settings.windowWidth, height: Design.Settings.maximumHeight)
            window.setFrameAutosaveName("SevenSettingsWindowV2")
            window.contentView = NSHostingView(rootView: SettingsView(
                model: model,
                replacementHotKeyManager: replacementHotKeyManager,
                inputHotKeyManager: inputHotKeyManager,
                hotKeyManager: hotKeyManager,
                screenshotHotKeyManager: screenshotHotKeyManager,
                pinVisibilityHotKeyManager: pinVisibilityHotKeyManager, clipboardPinHotKeyManager: clipboardPinHotKeyManager,
                regionCaptureHotKeyManager:regionCaptureHotKeyManager ?? HotKeyManager(storageKey:"regionCaptureHotKey.v1",identifierID:7,allowsUnset:true),
                fullCaptureHotKeyManager:fullCaptureHotKeyManager ?? HotKeyManager(storageKey:"fullCaptureHotKey.v1",identifierID:8,allowsUnset:true),
                previousCaptureHotKeyManager:previousCaptureHotKeyManager ?? HotKeyManager(storageKey:"previousCaptureHotKey.v1",identifierID:9,allowsUnset:true),
                closePinHotKeyManager:closePinHotKeyManager ?? ScreenshotPinShortcuts.closeCurrent(),
                closeAllPinsHotKeyManager:closeAllPinsHotKeyManager ?? ScreenshotPinShortcuts.closeAll(),
                ocrShortcuts:ocrShortcuts ?? OCRShortcuts(),
                imageEntryShortcuts:imageEntryShortcuts ?? ImageEntryShortcuts(),
                toolbarPreferences:.shared,
                launchAtLogin: launchAtLogin,
                history: history,
                dictionaryManager: dictionaryManager,
                diagnostics: diagnostics,
                updater: updater,
                sectionRequests: sectionRequests
            ))
            window.center()
            return window
        }
        super.init(window: nil)
    }

    // 声明按需加载身份；loadWindow 直接构建窗口，不读取 nib 文件。
    override var windowNibName: NSNib.Name? { NSNib.Name("SettingsWindow") }

    override func loadWindow() {
        guard let makeWindow else { return }
        window = makeWindow()
        window?.delegate = self
        self.makeWindow = nil
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        (notification.object as? SettingsCloseConfirmingWindow)?.onClose?()
    }

    override func showWindow(_ sender: Any?) {
        if window?.isVisible == false { launchAtLogin.refresh() }
        super.showWindow(sender)
    }

    func show(section: SettingsSection? = nil) {
        if let section { sectionRequests.send(section) }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
