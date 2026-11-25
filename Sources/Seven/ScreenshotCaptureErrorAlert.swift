import AppKit

@MainActor
enum ScreenshotCaptureErrorAlert {
    static func show(
        _ error: ScreenshotTranslationError,
        present: @MainActor (NSAlert) -> NSApplication.ModalResponse = { AppAlert.runModal($0) },
        authorize: ((PermissionGuide.Permission) -> Void)? = nil
    ) {
        if error == .permissionDenied {
            AppAlert.confirmPermission(.screenRecording, present: present, authorize: authorize)
            return
        }
        let alert = NSAlert()
        alert.messageText = error.localizedDescription
        alert.addButton(withTitle: L10n.text("ok"))
        _ = present(alert)
    }
}
