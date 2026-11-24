import SwiftUI
import AppKit
import CoreGraphics
import Observation

/// 当前设置页面的一次性反馈，和已保存配置及系统状态分别持有。
@MainActor @Observable
final class SettingsPageFeedback {
    enum ServiceOperation {
        case saved
        case failed(LocalizedMessage)

        var message: LocalizedMessage {
            switch self {
            case .saved: return .key("saved")
            case .failed(let message): return message
            }
        }

        var isError: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    var shortcutResetIssues: [ObjectIdentifier: LocalizedMessage] = [:]
    var toolbarResetFailures: Set<ScreenshotToolbarAction> = []
    var serviceOperation: ServiceOperation?
    var keyIsRevealed = false

    func clear() {
        shortcutResetIssues.removeAll()
        toolbarResetFailures.removeAll()
        serviceOperation = nil
        keyIsRevealed = false
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case translation, service, speech, history, screenshot, pin, toolbar, ocr, general, privacy, about
#if DEBUG || SEVEN_DEVELOPMENT
    case diagnostics
#endif

    var id: Self { self }
    var title: String {
        switch self {
        case .translation: return L10n.text("translationSettings")
        case .service: return L10n.text("translationServices")
        case .speech: return L10n.text("textToSpeech")
        case .history: return L10n.text("history.title")
        case .screenshot: return L10n.text("screenshotSettings")
        case .pin: return L10n.text("pinnedImages")
        case .toolbar: return L10n.text("toolbar")
        case .ocr: return L10n.text("ocrSettings")
        case .general: return L10n.text("generalSettings")
        case .privacy: return L10n.text("privacy")
        case .about: return L10n.text("about")
#if DEBUG || SEVEN_DEVELOPMENT
        case .diagnostics: return L10n.text("diagnostics")
#endif
        }
    }
    var icon: String {
        switch self {
        case .translation: return "character.book.closed"
        case .service: return "network"
        case .speech: return "speaker.wave.2"
        case .history: return "clock.arrow.circlepath"
        case .screenshot: return "camera.viewfinder"
        case .pin: return "pin"
        case .toolbar: return "slider.horizontal.3"
        case .ocr: return "text.viewfinder"
        case .general: return "gearshape"
        case .privacy: return "hand.raised"
        case .about: return "info.circle"
#if DEBUG || SEVEN_DEVELOPMENT
        case .diagnostics: return "stethoscope"
#endif
        }
    }

    var sidebarTitle: String {
        switch self {
        case .translation: return L10n.text("settings.sidebar.languages")
        case .service: return L10n.text("settings.sidebar.services")
        case .speech: return L10n.text("settings.sidebar.speech")
        case .screenshot: return L10n.text("settings.sidebar.capture")
        case .pin: return L10n.text("settings.sidebar.pins")
        case .toolbar: return L10n.text("settings.sidebar.toolbar")
        case .ocr: return L10n.text("settings.sidebar.recognition")
        case .general: return L10n.text("settings.sidebar.basics")
        case .about: return L10n.text("settings.sidebar.about")
        default: return title
        }
    }
}

enum SettingsNavigationGroup: String, CaseIterable, Identifiable {
    case translation, screenshot, ocr, general
    var id: Self { self }
    var title: String {
        switch self {
        case .translation: return L10n.text("translationGroup")
        case .screenshot: return L10n.text("screenshot")
        case .ocr: return "OCR"
        case .general: return L10n.text("general")
        }
    }
    var sections: [SettingsSection] {
        switch self {
        case .translation: return [.translation, .service, .speech, .history]
        case .screenshot: return [.screenshot, .pin, .toolbar]
        case .ocr: return [.ocr]
        case .general:
#if DEBUG || SEVEN_DEVELOPMENT
            return [.general, .privacy, .about, .diagnostics]
#else
            return [.general, .privacy, .about]
#endif
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: TranslationModel
    @ObservedObject var replacementHotKeyManager: HotKeyManager
    @ObservedObject var inputHotKeyManager: HotKeyManager
    @ObservedObject var hotKeyManager: HotKeyManager
    @ObservedObject var screenshotHotKeyManager: HotKeyManager
    @ObservedObject var pinVisibilityHotKeyManager: HotKeyManager
    @ObservedObject var clipboardPinHotKeyManager: HotKeyManager
    @ObservedObject var regionCaptureHotKeyManager:HotKeyManager
    @ObservedObject var fullCaptureHotKeyManager:HotKeyManager
    @ObservedObject var previousCaptureHotKeyManager:HotKeyManager
    @ObservedObject var closePinHotKeyManager:HotKeyManager
    @ObservedObject var closeAllPinsHotKeyManager:HotKeyManager
    let ocrShortcuts:OCRShortcuts
    let imageEntryShortcuts:ImageEntryShortcuts
    @ObservedObject var toolbarPreferences:ScreenshotToolbarPreferences
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var history: HistoryStore
    @ObservedObject var dictionaryManager: ECDictionaryManager
    let diagnostics: DiagnosticLogging

    @ObservedObject var interfaceLanguage = InterfaceLanguageState.shared
    @State private var selection: SettingsSection = .translation
    @State var selectedService: TranslationProviderID?
    @StateObject var serviceEditor = SettingsServiceDraft()
    let pageFeedback = SettingsPageFeedback()
    @State var apiKeyFocused = false
    @State var serviceLoadIssue: LocalizedMessage?
    var serviceMessage: String? { (pageFeedback.serviceOperation?.message ?? serviceLoadIssue)?.text }
    var serviceMessageIsError: Bool { pageFeedback.serviceOperation?.isError ?? (serviceLoadIssue != nil) }
    @State var isLoadingModels = false
    @State var modelCatalogIssue: LocalizedMessage?
    var modelCatalogMessage: String? { modelCatalogIssue?.text }
    @State var modelCatalogMessageIsError = false
    @State var modelCatalogRequestID: UUID?
    @State var modelCatalogSourceRevision: UUID?
    @State var addingService = false
    @State var deletingService = false
    @State var recordingInputShortcut = false
    @State var recordingReplacementShortcut = false
    var themeManager = ThemeManager.shared
    @State var panelPlacement = PanelPlacementMode.stored()
    @State var recordingShortcut = false
    @State var recordingScreenshotShortcut = false
    @AppStorage(ScreenshotShadowPreferences.captureEnabled) var screenshotShadowEnabled=false
    @AppStorage(ScreenshotShadowPreferences.captureOpacity) var screenshotShadowOpacity=Design.ScreenshotShadow.defaultOpacity
    @AppStorage(ScreenshotShadowPreferences.captureColor) var screenshotShadowColor="000000"
    @AppStorage(ScreenshotShadowPreferences.pinEnabled) var pinShadowEnabled=true
    @AppStorage(ScreenshotShadowPreferences.pinOpacity) var pinShadowOpacity=Design.ScreenshotShadow.defaultOpacity
    @AppStorage(ScreenshotShadowPreferences.pinColor) var pinShadowColor="000000"
    @State var recordingLongCaptureShortcut=false
    @State var recordingLocalImageShortcut=false
    @State var recordingClipboardImageShortcut=false
    @State var recordingClipboardOCRShortcut=false
    @State var recordingFileOCRShortcut=false
    @State var recordingRegionCaptureShortcut=false
    @State var recordingFullCaptureShortcut=false
    @State var recordingPreviousCaptureShortcut=false
    @AppStorage(FrozenCapturePurpose.ocr.smartSelectionKey) var ocrSmartSelectionEnabled = true
    @AppStorage(FrozenCapturePurpose.translation.smartSelectionKey) var translationSmartSelectionEnabled = true
    @AppStorage(OCRRecognitionLanguages.preferenceKey) var ocrRecognitionLanguage = LanguageCatalog.automatic
    @State var recordingOCRMode:OCRMode?
    @State var recordingOpenOCRShortcut = false
    @State var recordingToolbarAction:ScreenshotToolbarAction?
    @AppStorage(ScreenshotCapturePreferences.completionSoundKey) var screenshotCompletionSound=true
    @AppStorage(ScreenshotCapturePreferences.crosshairKey) var showScreenshotCrosshair=true
    @AppStorage(ScreenshotCapturePreferences.magnifierKey) var showScreenshotMagnifier=true
    @AppStorage(ScreenshotCapturePreferences.hintsKey) var showScreenshotHints=true
    @AppStorage(ScreenshotCapturePreferences.doubleClickKey) var screenshotDoubleClick=ScreenshotDoubleClickAction.copy
    @AppStorage(ScreenshotSavePreferences.locationKey) var screenshotSaveLocation=ScreenshotSaveLocation.ask
    @AppStorage(ScreenshotSavePreferences.folderKey) var screenshotSaveFolder=""
    @AppStorage(ScreenshotSavePreferences.formatKey) var screenshotSaveFormat=ScreenshotSaveFormat.png
    @State var recordingPinVisibilityShortcut = false
    @State var recordingClosePinShortcut=false
    @State var recordingCloseAllPinsShortcut=false
    @State var recordingClipboardPinShortcut = false
    @AppStorage(ScreenshotPinPreferences.zoomKey) var pinZoomWheel = ScreenshotPinWheel.command
    @AppStorage(ScreenshotPinPreferences.opacityWheelKey) var pinOpacityWheel = ScreenshotPinWheel.option
    @State var updateButtonEnabled = true
    @State var automaticUpdatesEnabled = false
#if DEBUG || SEVEN_DEVELOPMENT
    @State var diagnosticText = ""
    @State var confirmingLogClear = false
#endif
    @State var confirmingDictionaryDelete = false
    @AppStorage(ScreenshotToolPreferences.smartSelectionKey) var smartSelectionEnabled = true
#if DEBUG || SEVEN_DEVELOPMENT
    @AppStorage(ScreenshotScrollTrace.enabledKey) var scrollDiagnosticsEnabled = false
#endif
    @State var screenCaptureTrusted = CGPreflightScreenCaptureAccess()

    var allHotKeyManagers: [HotKeyManager] { [inputHotKeyManager, hotKeyManager, screenshotHotKeyManager, replacementHotKeyManager, pinVisibilityHotKeyManager, clipboardPinHotKeyManager,closePinHotKeyManager,closeAllPinsHotKeyManager,regionCaptureHotKeyManager,fullCaptureHotKeyManager,previousCaptureHotKeyManager]+ocrShortcuts.managers+imageEntryShortcuts.managers }

    var body: some View { ThemedContent(content: navigation, manager: themeManager) }

    private var navigation: some View {
        splitNavigation
            .alert(L10n.text("saveChangesToThisService"), isPresented: $serviceEditor.confirmsDeparture) {
                Button(L10n.text("save")) { saveServiceAndDepart() }
                Button(L10n.text("donTSave"), role: .destructive) { serviceEditor.discardAndDepart() }
                Button(L10n.text("cancel"), role: .cancel) { serviceEditor.cancelDeparture() }
            } message: {
                Text(L10n.text("thisServiceHasUnsavedChanges"))
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                screenCaptureTrusted = CGPreflightScreenCaptureAccess()
            }
#if DEBUG || SEVEN_DEVELOPMENT
            .task(id: selection) {
                if selection == .diagnostics { await refreshDiagnostics() }
            }
            .confirmationDialog("清空本地诊断日志？", isPresented: $confirmingLogClear) {
                Button("清空日志", role: .destructive) {
                    Task { await diagnostics.clear(); await refreshDiagnostics() }
                }
                Button("取消", role: .cancel) {}
            }
#endif
            .confirmationDialog(L10n.text("deleteTheOfflineECDICTDictionary"), isPresented: $confirmingDictionaryDelete) {
                Button(L10n.text("deleteDictionary"), role: .destructive) {
                    model.setServiceEnabled(.ecdict, enabled: false)
                    dictionaryManager.delete()
                }
                Button(L10n.text("cancel"), role: .cancel) {}
            }
    }

    private var splitNavigation: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            detailContent
        }
        .frame(minWidth: Design.Settings.windowWidth, maxWidth: Design.Settings.windowWidth,
               minHeight: Design.Settings.minimumHeight)
        .onAppear {
            dictionaryManager.refresh()
            screenCaptureTrusted = CGPreflightScreenCaptureAccess()
            if selectedService == nil { selectedService = model.serviceInstances.first?.id }
            prepareServiceDraft()
        }
        .onChange(of: selectedService) { prepareServiceDraft() }
        .overlay {
            SettingsServiceCloseGuard { window in
                guard serviceEditor.hasChanges else { return true }
                serviceEditor.requestDeparture { window.performClose(nil) }
                return false
            } onClose: {
                clearPageFeedback()
                launchAtLogin.refresh()
            }
            .frame(width: 0, height: 0)
        }
        .environment(\.locale, L10n.locale)
    }

    private var sidebarSelection: Binding<SettingsSection> {
        Binding(get: { selection }, set: { next in
            guard next != selection else { return }
            serviceEditor.requestDeparture {
                clearPageFeedback()
                if selection == .general || next == .general { launchAtLogin.refresh() }
                selection = next
            }
        })
    }

    private var sidebarContent: some View {
        let language = L10n.language
        return List(selection: sidebarSelection) {
            ForEach(SettingsNavigationGroup.allCases) { group in
                Section(group.title) {
                    ForEach(group.sections) { section in
                        Label(section.sidebarTitle, systemImage: section.icon)
                            .themeSidebarRow(selected: section == selection).tag(section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .themeSidebar()
        // 语言变化时重建原生列表的标题和行，选中的页面由设置窗口持有。
        .id(language)
        .navigationSplitViewColumnWidth(
            min: Design.Settings.navigationWidth,
            ideal: Design.Settings.navigationWidth,
            max: Design.Settings.navigationWidth
        )
        .toolbar(removing: .sidebarToggle)
    }

    private var detailContent: some View {
        let title = selection.title
        return detail.themeDetailSurface().navigationTitle(title)
            .settingsOverlayScrollbars()
            .toolbar {
                if #available(macOS 26, *) {
                    pageTitleItem(title).sharedBackgroundVisibility(.hidden)
                } else {
                    pageTitleItem(title)
                }
            }
    }

    private func clearPageFeedback() {
        pageFeedback.clear()
        apiKeyFocused = false
        cancelModelCatalogRequest()
        model.clearConfigurationTestResult()
    }

    private func pageTitleItem(_ title: String) -> some ToolbarContent {
        let palette = themeManager.palette
        return ToolbarItem(id: "settings.pageTitle", placement: .navigation) {
            Text(title)
                .font(Design.Text.settingsPageTitle.font)
                .foregroundStyle(ThemeStyle.nativePrimary)
                .environment(\.theme, palette)
                .padding(.leading, Design.Settings.toolbarTitleLeadingPadding)
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .general: generalPane
        case .translation: translationPane
        case .history: historyPane
        case .screenshot: screenshotPane
        case .pin: pinPane
        case .toolbar: toolbarPane
        case .ocr:ocrPane
        case .privacy: SettingsForm { EmptyView() }
        case .about: aboutPane
        case .service: servicePane
        case .speech: speechPane
#if DEBUG || SEVEN_DEVELOPMENT
        case .diagnostics: diagnosticsPane
#endif
        }
    }

}
