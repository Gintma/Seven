import AppKit

@MainActor
enum AppAlert {
    @discardableResult
    static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    static func confirmPermission(
        _ permission: PermissionGuide.Permission,
        present: (NSAlert) -> NSApplication.ModalResponse,
        authorize: ((PermissionGuide.Permission) -> Void)?
    ) {
        let alert = NSAlert()
        let (title, settingsButton) = switch permission {
        case .screenRecording: ("sevenNeedsScreenRecordingPermissionToCapture", "openScreenRecordingSettings")
        case .accessibility: ("accessibilityPermissionRequired", "openAccessibilitySettings")
        }
        alert.messageText = L10n.text(title)
        alert.addButton(withTitle: L10n.text(settingsButton))
        alert.addButton(withTitle: L10n.text("cancel")).keyEquivalent = "\u{1b}"

        let previousApplication = authorize == nil ? NSWorkspace.shared.frontmostApplication : nil
        guard present(alert) == .alertFirstButtonReturn else { return }
        if let authorize {
            authorize(permission)
        } else {
            PermissionGuide.shared.authorize(permission, returningTo: previousApplication)
        }
    }
}
