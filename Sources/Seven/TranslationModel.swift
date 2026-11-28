import AppKit

@MainActor
final class TranslationModel: ObservableObject {
    enum RecoveryAction { case serviceSettings }
    struct HistoryRound {
        let sourceText: String
        let sourceLanguage: String
        let targetLanguage: String
        var record: TranslationRecord.Reference?
    }

    nonisolated static let languages = LanguageCatalog.codes
    static let automaticTarget = LanguageRouting.automaticTarget
    @Published var input = "" {
        didSet { if input != oldValue { inputDidChange() } }
    }
    /// Auto-detected source language (updated after input pauses); nil when input is empty or undetermined.
    @Published var detectedSource: String?
    /// Source language detection method; online detection is only used before translation when system detection is untrusted.
    @Published var languageDetectionMode: LanguageDetectionMode {
        didSet {
            settings.languageDetectionMode = languageDetectionMode
            languageDetectionModeDidChange(from: oldValue)
        }
    }
    internal let languageDetectors: [LanguageDetectionMode: OnlineLanguageDetecting]
    /// Online-confirmed source language valid only for the same source text; a nil code means online detection also found no catalog language.
    internal var confirmedDetection: (text: String, code: String?)?
    /// Reuses the local detection result for the current source text and language preferences across display, verification, and translation services.
    internal var localDetectionCache: (text: String, primary: String, secondary: String, result: LocalLanguageDetection)?
    /// Waits about 1 second after typing stops before detecting and updating the language bar.
    internal let languageDetectionDelay: Duration
    internal var detectionTask: Task<Void, Never>?
    /// Source text currently being detected and whether online detection has started.
    internal var detectingText: String?
    internal var isDetectingOnline = false
    /// Enter pressed while detection is still running: automatically start translation once detection completes.
    internal var translateAfterDetection = false
    /// Retrying, expanding, or enabling services while detection is still running: launch only those services once detection completes.
    internal var retryAfterDetection: [TranslationProviderID] = []
    @Published var source = LanguageCatalog.automatic { didSet { settings.sourceLanguage = source } }
    @Published var target = LanguageRouting.automaticTarget { didSet { settings.targetLanguage = target } }
    @Published var serviceResults: [TranslationServiceResult] = []
    @Published var isLoading = false
    @Published var status = "准备好，开始一段翻译。"
    @Published var issue: LocalizedMessage?
    var errorMessage: String? { issue?.text }
    @Published var rendersCustomResultsAsMarkdown: Bool {
        didSet { settings.rendersCustomResultsAsMarkdown = rendersCustomResultsAsMarkdown }
    }
    @Published var clearTranslationOnDismiss: Bool {
        didSet { settings.clearTranslationOnDismiss = clearTranslationOnDismiss }
    }
    @Published var pinned: Bool { didSet { settings.pinned = pinned } }
    @Published var serviceInstances: [ServiceInstance]
    @Published var recoveryAction: RecoveryAction?
    @Published var primaryLanguage: String
    /// Common languages listed directly in the language bar menu (only changed manually in Settings; never mutated by menu selection).
    @Published var commonLanguages: [String]
    @Published var secondaryLanguage: String
    @Published var resolvedTarget: String?
    @Published var isTestingConfiguration = false
    @Published var configurationTestIssue: LocalizedMessage?
    var configurationTestMessage: String? { configurationTestIssue?.text }
    @Published var configurationTestSucceeded = false
    @Published var youdaoShowsPronunciations: Bool {
        didSet { settings.youdaoShowsPronunciations = youdaoShowsPronunciations }
    }
    @Published var youdaoShowsDefinitions: Bool {
        didSet { settings.youdaoShowsDefinitions = youdaoShowsDefinitions }
    }
    @Published var youdaoShowsPhrases: Bool {
        didSet { settings.youdaoShowsPhrases = youdaoShowsPhrases }
    }
    @Published var youdaoShowsExamples: Bool {
        didSet { settings.youdaoShowsExamples = youdaoShowsExamples }
    }
    @Published var inputMaximumHeight: Int
    @Published var maximumWindowHeightRatio: Double
    @Published var panelScreenHeight: CGFloat = 900
    @Published var expandedProviders = Set(TranslationProviderID.allCases)
    @Published var appleTranslationRequest: AppleTranslationRequest?
    let speech: SpeechController
    internal let service: TranslationServing
    internal let appleAvailability: AppleTranslationAvailabilityChecking
    internal let dictionaryService: DictionaryServing
    internal let youdaoService: OnlineTranslationServing
    internal let googleService: OnlineTranslationServing
    internal let configurationTester: ServiceConfigurationTesting
    internal let credentials: CredentialStoring
    internal let settings: SettingsStore
    internal let logger: DiagnosticLogging
    internal let history: HistoryStore?
    internal var serviceTasks: [TranslationProviderID: Task<Void, Never>] = [:]
    internal var configurationTestTask: Task<Void, Never>?
    internal var generation: UUID?
    internal var primaryResultID: TranslationProviderID?
    /// Shares the lifetime of the floating panel's current result round; kept after completion so single-service retries can update the existing record.
    internal var historyRound: HistoryRound?
    internal var systemTranslationBridgeAvailable = false
    var onHide: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onStartScreenshot: (() -> Void)?

    init(service: TranslationServing = CompatibleTranslationService(),
         dictionaryService: DictionaryServing = ECDictionaryService(),
         youdaoService: OnlineTranslationServing = YoudaoTranslationService(),
         googleService: OnlineTranslationServing = GoogleTranslationService(),
         credentials: CredentialStoring = CredentialStoreFactory.make(),
         settings: SettingsStore = SettingsStore(),
         configurationTester: ServiceConfigurationTesting = CompatibleConfigurationTester(),
         logger: DiagnosticLogging = NoopDiagnosticLogger(),
         history: HistoryStore? = nil,
         speech: SpeechController? = nil,
         languageDetectors: [LanguageDetectionMode: OnlineLanguageDetecting]? = nil,
         appleAvailability: AppleTranslationAvailabilityChecking = SystemAppleTranslationAvailability(),
         languageDetectionDelay: Duration = .seconds(1)) {
        self.appleAvailability = appleAvailability
        if let languageDetectors {
            self.languageDetectors = languageDetectors
        } else {
            var detectors: [LanguageDetectionMode: OnlineLanguageDetecting] = [
                .google: GoogleLanguageDetector(), .baidu: BaiduLanguageDetector()
            ]
            detectors[.youdao] = youdaoService as? OnlineLanguageDetecting
            self.languageDetectors = detectors
        }
        self.languageDetectionDelay = languageDetectionDelay
        self.languageDetectionMode = settings.languageDetectionMode
        self.service = service
        self.dictionaryService = dictionaryService
        self.youdaoService = youdaoService
        self.googleService = googleService
        self.credentials = credentials
        self.settings = settings
        self.speech = speech ?? SpeechController(settings: settings, logger: logger)
        self.configurationTester = configurationTester
        self.logger = logger
        self.history = history
        self.serviceInstances = settings.migrateServiceInstances()
        self.rendersCustomResultsAsMarkdown = settings.rendersCustomResultsAsMarkdown
        self.clearTranslationOnDismiss = settings.clearTranslationOnDismiss
        self.pinned = settings.pinned
        self.source = settings.sourceLanguage
        self.target = settings.targetLanguage
        self.primaryLanguage = settings.primaryLanguage
        self.commonLanguages = settings.commonLanguages
        self.secondaryLanguage = settings.secondaryLanguage
        self.youdaoShowsPronunciations = settings.youdaoShowsPronunciations
        self.youdaoShowsDefinitions = settings.youdaoShowsDefinitions
        self.youdaoShowsPhrases = settings.youdaoShowsPhrases
        self.youdaoShowsExamples = settings.youdaoShowsExamples
        self.inputMaximumHeight = settings.inputMaximumHeight
        self.maximumWindowHeightRatio = settings.maximumWindowHeightRatio
        self.expandedProviders = Set(
            serviceInstances.map(\.id).filter { settings.isServiceExpanded($0) }
        )
    }

    // MARK: Request Invariants

    internal static let noServicesIssue = LocalizedMessage.key("noTranslationServicesAreAvailableEnableOne")
    internal static let pausedServiceIssue = LocalizedMessage.key("translationIsPausedExpandThisResultTo")
    internal static let dictionaryInputIssue = LocalizedMessage.key("skippedThisDictionaryLooksUpEnglishWords")
    static let dictionaryMissIssue = LocalizedMessage.key("theOfflineDictionaryHasNoEntryFor")

#if DEBUG
    func setServiceResultsForTesting(_ results: [TranslationServiceResult]) {
        serviceResults = results
        isLoading = results.contains { $0.phase.isRunning }
    }
#endif
}
