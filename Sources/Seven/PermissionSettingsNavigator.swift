import AppKit

@MainActor
protocol PermissionSettingsOpening {
    func launchSettings() async throws
    func openPane(_ url: URL) -> Bool
    func activateSettings()
}

@MainActor
struct SystemPermissionSettings: PermissionSettingsOpening {
    func launchSettings() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(
            at: URL(filePath: "/System/Applications/System Settings.app", directoryHint: .checkFileSystem),
            configuration: configuration
        )
    }

    func openPane(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    func activateSettings() {
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.systempreferences"
        ).first else { return }
        NSApplication.shared.yieldActivation(to: application)
        application.activate(from: .current, options: [.activateAllWindows])
    }
}

@MainActor
struct PermissionSettingsNavigator {
    let workspace: any PermissionSettingsOpening

    init(workspace: any PermissionSettingsOpening) {
        self.workspace = workspace
    }

    func open(_ url: URL) async -> Bool {
        do {
            try await workspace.launchSettings()
        } catch {
            return false
        }
        guard !Task.isCancelled else { return false }
        let opened = workspace.openPane(url)
        workspace.activateSettings()
        return opened
    }
}
