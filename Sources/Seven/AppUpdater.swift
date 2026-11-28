import Combine
import Foundation
import Sparkle

struct AppUpdateConfiguration {
    static let repositoryURL = URL(string: "https://github.com/crismakes/Seven")!

    enum Availability: Equatable {
        case supported
        case development
        case unconfigured
    }

    let availability: Availability
    let releaseNotesURL: URL

    init(bundleIdentifier: String?, isDevelopmentBuild: Bool, version: String?, feed: String?, publicKey: String?) {
        let releases = Self.repositoryURL.appendingPathComponent("releases")
        // Only the official main bundle uses Sparkle; all other builds fall back to the releases list.
        let development = isDevelopmentBuild || bundleIdentifier != AppDataPaths.bundleIdentifier
        let releaseURL: URL
        if !development, let version, version.range(of: #"^[0-9]+(\.[0-9]+){1,2}$"#, options: .regularExpression) != nil {
            releaseURL = releases.appendingPathComponent("tag").appendingPathComponent("v\(version)")
        } else {
            releaseURL = releases
        }
        releaseNotesURL = releaseURL

        if development {
            availability = .development
        } else if let feed, let url = URL(string: feed), url.scheme == "https", url.host?.isEmpty == false,
                  let publicKey, let key = Data(base64Encoded: publicKey), key.count == 32, key.contains(where: { $0 != 0 }) {
            availability = .supported
        } else {
            availability = .unconfigured
        }
    }

    static var current: Self {
        #if DEBUG || SEVEN_DEVELOPMENT
        let isDevelopmentBuild = true
        #else
        let isDevelopmentBuild = false
        #endif
        let bundle = Bundle.main
        return Self(
            bundleIdentifier: bundle.bundleIdentifier,
            isDevelopmentBuild: isDevelopmentBuild,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        )
    }
}

@MainActor
protocol AppUpdateBackend: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var onChange: ((AppUpdateEvent) -> Void)? { get set }

    func start() throws
    func checkForUpdates()
}

enum AppUpdateEvent {
    case canCheck(Bool)
    case updateAvailable(Bool)
    case automaticDownloadsChanged(Bool)
}

@MainActor
final class AppUpdater: ObservableObject {
    private let defaults: UserDefaults
    private var backend: (any AppUpdateBackend)?
    private static let legacyAutomaticKey = "updates.automatic.v1"
    private static let automaticDownloadsKey = "updates.automaticDownloads.v1"
    private static let shortcutKey = "updates.showShortcut.v1"

    @Published private(set) var availability: AppUpdateConfiguration.Availability
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var updateAvailable = false
    @Published var automaticDownloadsEnabled: Bool {
        didSet {
            guard automaticDownloadsEnabled != oldValue else { return }
            defaults.set(automaticDownloadsEnabled, forKey: Self.automaticDownloadsKey)
            syncAutomaticDownloads()
        }
    }
    @Published var updateButtonEnabled: Bool {
        didSet { defaults.set(updateButtonEnabled, forKey: Self.shortcutKey) }
    }
    let releaseNotesURL: URL

    var showsUpdateShortcut: Bool { availability == .supported && updateAvailable && updateButtonEnabled }
    var isChecking: Bool { availability == .supported && !canCheckForUpdates }

    init(defaults: UserDefaults, configuration: AppUpdateConfiguration, makeBackend: () -> any AppUpdateBackend) {
        self.defaults = defaults
        availability = configuration.availability
        releaseNotesURL = configuration.releaseNotesURL
        let legacyAutomatic = defaults.object(forKey: Self.legacyAutomaticKey) as? Bool
        let storedDownloads = defaults.object(forKey: Self.automaticDownloadsKey) as? Bool
        automaticDownloadsEnabled = storedDownloads ?? legacyAutomatic ?? false
        updateButtonEnabled = defaults.object(forKey: Self.shortcutKey) as? Bool ?? true
        if storedDownloads == nil, let legacyAutomatic {
            defaults.set(legacyAutomatic, forKey: Self.automaticDownloadsKey)
        }

        guard configuration.availability == .supported else { return }
        let backend = makeBackend()
        self.backend = backend
        if !backend.automaticallyChecksForUpdates {
            backend.automaticallyChecksForUpdates = true
        }
        syncAutomaticDownloads()
        do {
            try backend.start()
        } catch {
            self.backend = nil
            availability = .unconfigured
            return
        }
        canCheckForUpdates = backend.canCheckForUpdates
        backend.onChange = { [weak self] event in self?.receive(event) }
    }

    static func makeForCurrentApp(defaults: UserDefaults) -> AppUpdater {
        AppUpdater(defaults: defaults, configuration: .current) { SparkleUpdateBackend() }
    }

    func checkForUpdates() {
        guard let backend, backend.canCheckForUpdates else { return }
        backend.checkForUpdates()
        canCheckForUpdates = backend.canCheckForUpdates
    }

    func installAvailableUpdate() {
        guard showsUpdateShortcut else { return }
        checkForUpdates()
    }

    private func receive(_ event: AppUpdateEvent) {
        switch event {
        case .canCheck(let allowed):
            canCheckForUpdates = allowed
        case .updateAvailable(let available):
            updateAvailable = available
        case .automaticDownloadsChanged(let enabled):
            if enabled != automaticDownloadsEnabled { automaticDownloadsEnabled = enabled }
        }
    }

    private func syncAutomaticDownloads() {
        guard let backend, backend.automaticallyDownloadsUpdates != automaticDownloadsEnabled else { return }
        backend.automaticallyDownloadsUpdates = automaticDownloadsEnabled
    }
}

@MainActor
private final class SparkleUpdateBackend: NSObject, AppUpdateBackend, SPUUpdaterDelegate {
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
    )
    private var checkObservation: NSKeyValueObservation?
    private var downloadsObservation: NSKeyValueObservation?
    var onChange: ((AppUpdateEvent) -> Void)?

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func start() throws {
        // Start the underlying updater directly so configuration errors surface in the About pane status banner.
        try controller.updater.start()
        checkObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.onChange?(.canCheck(self.canCheckForUpdates))
            }
        }
        downloadsObservation = controller.updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.onChange?(.automaticDownloadsChanged(self.automaticallyDownloadsUpdates))
            }
        }
    }

    func checkForUpdates() {
        // Sparkle resumes an already-downloaded update or brings an existing install prompt to the front.
        controller.updater.checkForUpdates()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        onChange?(.updateAvailable(!item.isInformationOnlyUpdate))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        onChange?(.updateAvailable(false))
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip { onChange?(.updateAvailable(false)) }
    }
}
