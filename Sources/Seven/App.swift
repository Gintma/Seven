import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    internal var item: NSStatusItem!
    internal var panel: TranslationPanel?
    internal var selectionMenuItem: NSMenuItem!
    internal var screenshotMenuItem: NSMenuItem!
    internal private(set) var settingsWindowController: SettingsWindowController!
    internal private(set) var historyWindowController: HistoryWindowController!
    internal var localKeyMonitor: Any?
    internal var selectionTask: Task<Void, Never>?
    internal var selectionGate = OperationGate()
    internal var screenshotTask: Task<Void, Never>?
    internal var screenshotGate = OperationGate()
    internal var screenshotTermination = ScreenshotTerminationCoordinator { NSApp.reply(toApplicationShouldTerminate: $0) }
    /// 浮窗是否已有上次的位置；有则每次弹出都回到那里，不再跟随鼠标。
    internal var hasRememberedPanelPosition = false
    internal static let panelFrameName = "SevenTranslationPanelV2"
    internal var preferredPanelHeight: CGFloat = 440
    internal let logger: DiagnosticLogging = FileDiagnosticLogger.shared
    private let historyStore = HistoryStore()
    private let dictionaryManager = ECDictionaryManager()
    internal private(set) lazy var model = TranslationModel(logger: logger, history: historyStore)
    internal let hotKeyManager = HotKeyManager()
    internal let screenshotHotKeyManager = HotKeyManager(
        storageKey: "screenshotHotKey.v1",
        defaultShortcut: .screenshotDefault,
        identifierID: 2,
        actionLabel: "截图翻译"
    )
    internal let regionCaptureHotKeyManager = HotKeyManager(storageKey:"regionCaptureHotKey.v1",identifierID:7,actionLabel:"截图",allowsUnset:true)
    internal let fullCaptureHotKeyManager = HotKeyManager(storageKey:"fullCaptureHotKey.v1",identifierID:8,actionLabel:"全屏截图",allowsUnset:true)
    internal let previousCaptureHotKeyManager = HotKeyManager(storageKey:"previousCaptureHotKey.v1",identifierID:9,actionLabel:"截图上次区域",allowsUnset:true)
    internal let pinVisibilityHotKeyManager = HotKeyManager(storageKey: "pinVisibilityHotKey.v1", identifierID: 5, actionLabel: "隐藏／显示钉图", allowsUnset: true)
    internal let clipboardPinHotKeyManager = HotKeyManager(storageKey: "clipboardPinHotKey.v1", identifierID: 6, actionLabel: "从剪贴板钉图", allowsUnset: true)
    internal let imageEntryShortcuts=ImageEntryShortcuts()
    internal var imageEntriesReady=false
    internal var pendingImageURLs:[URL]=[]
    internal let ocrShortcuts=OCRShortcuts()
    internal let ocrCoordinator=OCRCoordinator()
    internal var ocrWindowController: ScreenshotOCRWindowController?
    internal let closePinHotKeyManager=ScreenshotPinShortcuts.closeCurrent()
    internal let closeAllPinsHotKeyManager=ScreenshotPinShortcuts.closeAll()
    internal let inputHotKeyManager = HotKeyManager(
        storageKey: "inputHotKey.v1",
        defaultShortcut: .inputDefault,
        identifierID: 3,
        actionLabel: "输入翻译"
    )
    internal let replacementHotKeyManager = HotKeyManager(
        storageKey: "replacementHotKey.v1", defaultShortcut: .replacementDefault,
        identifierID: 4, actionLabel: "翻译并替换"
    )
    internal private(set) lazy var inputReplacement: InputReplacementCoordinator = {
        #if DEBUG || SEVEN_DEVELOPMENT
        let trace: (@Sendable (String) -> Void)? = { InputReplacementTarget.trace($0) }
        #else
        let trace: (@Sendable (String) -> Void)? = nil
        #endif
        return InputReplacementCoordinator(trace: trace) { [weak self] in
            TranslationModel(logger: self?.logger ?? FileDiagnosticLogger.shared)
        }
    }()
    internal var replacementMenuItem: NSMenuItem!
    internal var inputMenuItem: NSMenuItem!
    internal let selectionReader = SelectionReader()
    internal let frozenScreenshotCapture = FrozenScreenshotCaptureCoordinator()
    internal var scrollCapture: ScreenshotScrollWindowController?
    internal var screenshotEditors: [ScreenshotEditorWindowController] = []
    internal let textRecognizer: TextRecognizing = VisionTextRecognizer()
    private let launchAtLogin = LaunchAtLoginController()
    private let onboarding: OnboardingFlow?
    internal private(set) var onboardingWindowController: OnboardingWindowController?

    init(onboarding: OnboardingFlow? = nil) {
        self.onboarding = onboarding
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ThemeManager.shared.start(observing: NSApp)
        setupMenu()
        setupStatusItem()
        setupAuxiliaryWindows()
        connectModelActions()
        setupHotKeys()
        NotificationCenter.default.addObserver(
            self, selector: #selector(interfaceLanguageDidChange(_:)),
            name: InterfaceLanguageState.didChange, object: InterfaceLanguageState.shared
        )
        Task { await logger.record(.info, "app_launched", metadata: [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        ]) }
        let shouldShowOnboarding = onboarding?.shouldShow(hasPendingImages: !pendingImageURLs.isEmpty) == true
        imageEntriesReady = true
        if !pendingImageURLs.isEmpty {
            let urls = pendingImageURLs; pendingImageURLs.removeAll()
            openImageFiles(urls)
        } else if shouldShowOnboarding {
            showOnboarding()
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        screenshotTermination.requestTermination {
            cancelScreenshotWork()
            inputReplacement.terminate()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.cancel()
        cancelSelectionWork()
        cancelScreenshotWork()
        imageEntryShortcuts.managers.forEach { $0.stop() }
        ocrWindowController?.dispose(); ocrWindowController = nil
        hotKeyManager.stop()
        screenshotHotKeyManager.stop()
        inputHotKeyManager.stop()
        regionCaptureHotKeyManager.stop();fullCaptureHotKeyManager.stop();previousCaptureHotKeyManager.stop()
        replacementHotKeyManager.stop()
        pinVisibilityHotKeyManager.stop(); clipboardPinHotKeyManager.stop();closeAllPinsHotKeyManager.stop();ocrShortcuts.managers.forEach{$0.stop()}
        ScreenshotAuxiliaryWindows.closeAllPins()
        inputReplacement.terminate()
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        localKeyMonitor = nil
    }

    private func setupAuxiliaryWindows() {
        settingsWindowController = SettingsWindowController(
            model: model,
            inputHotKeyManager: inputHotKeyManager,
            replacementHotKeyManager: replacementHotKeyManager,
            hotKeyManager: hotKeyManager,
            screenshotHotKeyManager: screenshotHotKeyManager,
            pinVisibilityHotKeyManager: pinVisibilityHotKeyManager, clipboardPinHotKeyManager: clipboardPinHotKeyManager,
            ocrShortcuts:ocrShortcuts, imageEntryShortcuts:imageEntryShortcuts,
            closePinHotKeyManager:closePinHotKeyManager,closeAllPinsHotKeyManager:closeAllPinsHotKeyManager,
            regionCaptureHotKeyManager:regionCaptureHotKeyManager,fullCaptureHotKeyManager:fullCaptureHotKeyManager,previousCaptureHotKeyManager:previousCaptureHotKeyManager,
            launchAtLogin: launchAtLogin,
            history: historyStore,
            dictionaryManager: dictionaryManager,
            diagnostics: logger
        )
        historyWindowController = HistoryWindowController(store: historyStore)
    }

    private func showOnboarding() {
        guard let onboarding else { return }
        let controller = OnboardingWindowController(
            flow: onboarding,
            launchAtLogin: launchAtLogin,
            openInput: { [weak self] in
                guard let self else { return }
                showPanel()
                (panel?.contentViewController as? AppKitTranslationViewController)?.focusInput()
            },
            didClose: { [weak self] in self?.onboardingWindowController = nil }
        )
        onboardingWindowController = controller
        controller.show()
    }

    private func connectModelActions() {
        model.onHide = { [weak self] in self?.panel?.orderOut(nil) }
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        model.onOpenHistory = { [weak self] in self?.showHistory() }
        model.onStartScreenshot = { [weak self] in self?.startScreenshotTranslation() }
    }

}

@main
enum SevenApp {
    @MainActor static func main() {
        let defaults = UserDefaults.standard
        if CommandLine.arguments.contains("--check-credential-access") {
            do {
                let store = CredentialStoreFactory.make()
                let instances = SettingsStore().serviceInstances ?? []
                let present = try instances.filter { !$0.provider.isBuiltIn }.contains { try !store.read(account: $0.configuration.credentialAccount).isEmpty }
                print("credential_present=\(present)")
            } catch {
                try? FileHandle.standardError.write(contentsOf: Data("credential_access_failed\n".utf8))
                Foundation.exit(EXIT_FAILURE)
            }
            return
        }
        // 快捷键装配会保存默认键位，必须先读取升级前的使用痕迹。
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let onboarding = OnboardingFlow(defaults: defaults, hasExistingUsage: OnboardingFlow.hasExistingUsage(
            preferences: defaults.persistentDomain(forName: bundleIdentifier ?? "Seven") ?? [:],
            dataDirectory: AppDataPaths.directory(variant: AppDataPaths.variant(bundleIdentifier: bundleIdentifier))
        ))
        let app = NSApplication.shared
        let delegate = AppDelegate(onboarding: onboarding)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
