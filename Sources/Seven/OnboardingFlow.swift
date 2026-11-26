import Foundation

@MainActor
struct OnboardingFlow {
    static let storageKey = "onboarding.v1"

    private enum Status: String {
        case pending
        case completed
    }

    enum Reaction: String, CaseIterable {
        case accessibility, screenRecording, login
        fileprivate var key: String { "onboarding.awaiting." + rawValue }
    }

    func awaitSuccess(_ reaction: Reaction) {
        defaults.set(true, forKey: reaction.key)
    }

    func forget(_ reaction: Reaction) {
        defaults.removeObject(forKey: reaction.key)
    }

    /// 持久化的请求只在窗口可见且系统确认成功后消费，允许授权期间重启。
    func nextReaction(accessibility: Bool, screenRecording: Bool, login: LaunchAtLoginState) -> Reaction? {
        for reaction in Reaction.allCases where defaults.bool(forKey: reaction.key) {
            let ready = switch reaction {
            case .accessibility: accessibility
            case .screenRecording: screenRecording
            case .login: login == .enabled
            }
            if ready {
                forget(reaction)
                return reaction
            }
        }
        return nil
    }

    enum Action {
        case start
        case dismiss
    }

    private let defaults: UserDefaults
    private let hadExistingUsage: Bool

    init(defaults: UserDefaults, hasExistingUsage: @autoclosure () -> Bool) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.storageKey).flatMap(Status.init(rawValue:))
        hadExistingUsage = stored == nil && hasExistingUsage()
    }

    func shouldShow(hasPendingImages: Bool) -> Bool {
        switch status {
        case .completed:
            return false
        case .pending:
            return !hasPendingImages
        case nil:
            if hadExistingUsage {
                if !hasPendingImages { save(.completed) }
                return false
            }
            // 装配和图片处理会生成业务设置，后续启动应继续以待完成状态为准。
            save(.pending)
            return !hasPendingImages
        }
    }

    func finish(_ action: Action, close: () -> Void, openInput: () -> Void) {
        guard status == .pending else { return }
        Reaction.allCases.forEach(forget)
        save(.completed)
        close()
        if action == .start { openInput() }
    }

    private var status: Status? {
        defaults.string(forKey: Self.storageKey).flatMap(Status.init(rawValue:))
    }

    private func save(_ status: Status) {
        defaults.set(status.rawValue, forKey: Self.storageKey)
    }

    static func hasExistingUsage(preferences: [String: Any], dataDirectory: URL) -> Bool {
        let settingsKeys = [
            "serviceInstances.v2", "serviceConfiguration.v1", "configured",
            "appleTranslationEnabled", "ecdictEnabled", "youdaoEnabled", "googleEnabled", "customServiceEnabled",
            "selectionHotKey.v1", "screenshotHotKey.v1", "inputHotKey.v1", "replacementHotKey.v1",
            HotKeyManager.regionCaptureStorageKey, OCRShortcuts.captureStorageKey,
            "primaryLanguage", "secondaryLanguage", "sourceLanguage.v1", "targetLanguage.v1",
            "historyEnabled", HistoryStore.retentionKey, "pinned", PanelPlacementMode.storageKey,
            InterfaceLanguage.preferenceKey, AppearanceMode.storageKey, ThemeManager.lightThemeKey, ThemeManager.darkThemeKey,
            "NSWindow Frame SevenTranslationPanelV2", "NSWindow Frame SevenSettingsWindowV2", "NSWindow Frame SevenHistoryWindow"
        ]
        if settingsKeys.contains(where: { preferences[$0] != nil }) { return true }

        // 目录本身可能仅用于构建签名；只检查业务文件是否存在。
        let dataEntries = [
            "history.json", "history.recovery.json", "favorites.json", "favorites.recovery.json",
            "credentials.json", "ECDICT", "PinLibrary"
        ]
        return dataEntries.contains {
            FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent($0).fileSystemPath)
        }
    }
}
