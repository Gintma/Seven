import ServiceManagement

enum LaunchAtLoginState: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

protocol LaunchAtLoginServicing: AnyObject {
    var state: LaunchAtLoginState { get }
    func setEnabled(_ enabled: Bool) throws
}

protocol MainAppLoginRegistering {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: MainAppLoginRegistering {}

final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let service: any MainAppLoginRegistering
    init(service: any MainAppLoginRegistering = SMAppService.mainApp) { self.service = service }

    var state: LaunchAtLoginState {
        switch service.status {
        case .notRegistered, .notFound: return .disabled
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        @unknown default: return .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            // 新安装的 mainApp 在首次注册前也会返回 notFound。
            let status = service.status
            guard status != .enabled && status != .requiresApproval else { return }
            try service.register()
        } else {
            let status = service.status
            guard status != .notRegistered && status != .notFound else { return }
            try service.unregister()
        }
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var state: LaunchAtLoginState
    @Published private var issue: LocalizedMessage?
    var message: String? { issue?.text }
    private static let unavailableMessage = LocalizedMessage.key("loginItemStatusUnavailable")
    private let service: LaunchAtLoginServicing
    private let logger: DiagnosticLogging

    init(
        service: LaunchAtLoginServicing = SystemLaunchAtLoginService(),
        logger: DiagnosticLogging = FileDiagnosticLogger.shared
    ) {
        self.service = service
        self.logger = logger
        state = service.state
        refresh()
    }

    var enabled: Bool { state == .enabled || state == .requiresApproval }

    func refresh() {
        state = service.state
        switch state {
        case .enabled, .disabled:
            issue = nil
        case .requiresApproval:
            issue = .key("allowSevenInLoginItemsInSystem")
        case .unavailable:
            issue = Self.unavailableMessage
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            try service.setEnabled(enabled)
            state = service.state
            issue = state == .unavailable ? Self.unavailableMessage
                : state == .requiresApproval ? .key("allowSevenInLoginItemsInSystem") : nil
            Task { await logger.record(.info, "launch_at_login_changed", metadata: ["enabled": String(enabled)]) }
        } catch {
            state = service.state
            issue = state == .requiresApproval ? .key("allowSevenInLoginItemsInSystem")
                : .key("couldNotChangeLaunchAtLogin", .text(error.localizedDescription))
            Task { await logger.record(.error, "launch_at_login_failed", metadata: ["reason": String(describing: type(of: error))]) }
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
