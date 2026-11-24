import AppKit

@MainActor
final class TranslationModel: ObservableObject {
    enum RecoveryAction { case serviceSettings }
    enum PendingHistory: Equatable {
        case preferred(TranslationProviderID)
        case fallback
    }

    nonisolated static let languages = LanguageCatalog.codes
    static let automaticTarget = LanguageRouting.automaticTarget
    @Published var input = "" {
        didSet { if input != oldValue { inputDidChange() } }
    }
    /// 自动检测出的原文语言（输入停顿后更新）；没有原文或检测不出时为 nil。
    @Published var detectedSource: String?
    /// 原文语言的识别方式；联网方式只在系统识别结果不可信时、于翻译前使用。
    @Published var languageDetectionMode: LanguageDetectionMode {
        didSet {
            settings.languageDetectionMode = languageDetectionMode
            languageDetectionModeDidChange(from: oldValue)
        }
    }
    internal let languageDetectors: [LanguageDetectionMode: OnlineLanguageDetecting]
    /// 联网确认过的原文语言，只对同一段原文有效；nil 代码表示联网也未能识别出目录内的语言。
    internal var confirmedDetection: (text: String, code: String?)?
    /// 停止输入约 1 秒后再识别并更新语言栏。
    internal let languageDetectionDelay: Duration
    internal var detectionTask: Task<Void, Never>?
    /// 正在识别的原文及是否已进入联网阶段。
    internal var detectingText: String?
    internal var isDetectingOnline = false
    /// 按回车时识别尚未完成：识别结束后自动开始翻译。
    internal var translateAfterDetection = false
    /// 重试、展开或新启用服务时识别尚未完成：识别结束后只启动这些服务。
    internal var retryAfterDetection: [TranslationProviderID] = []
    @Published var source = LanguageCatalog.automatic { didSet { settings.sourceLanguage = source } }
    @Published var target = LanguageRouting.automaticTarget { didSet { settings.targetLanguage = target } }
    @Published var serviceResults: [TranslationServiceResult] = []
    @Published var isLoading = false
    @Published var status = "准备好，开始一段翻译。"
    @Published var issue: LocalizedMessage?
    var errorMessage: String? { issue?.text }
    @Published var clearTranslationOnDismiss: Bool {
        didSet { settings.clearTranslationOnDismiss = clearTranslationOnDismiss }
    }
    @Published var pinned: Bool { didSet { settings.pinned = pinned } }
    @Published var serviceInstances: [ServiceInstance]
    @Published var recoveryAction: RecoveryAction?
    @Published var primaryLanguage: String
    /// 语言栏菜单直接列出的常用语言（只在设置中手动修改，菜单不会自己变）。
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
    internal var pendingHistory: PendingHistory?
    /// 发起请求时记下的语言代码，写入历史；不读取之后变化的输入状态。
    internal var historyLanguages = (source: LanguageCatalog.automatic, target: LanguageCatalog.automatic)
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
         languageDetectors: [LanguageDetectionMode: OnlineLanguageDetecting] = [
            .google: GoogleLanguageDetector(), .baidu: BaiduLanguageDetector()
         ],
         appleAvailability: AppleTranslationAvailabilityChecking = SystemAppleTranslationAvailability(),
         languageDetectionDelay: Duration = .seconds(1)) {
        self.appleAvailability = appleAvailability
        self.languageDetectors = languageDetectors
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

    // MARK: 请求不变量

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
