import AppKit

@MainActor
enum ScreenshotCaptureErrorAlert {
    static func show(_ error: ScreenshotTranslationError) {
        show(error, present: { $0.runModal() }, authorize: {
            PermissionGuide.shared.authorize(.screenRecording)
        })
    }

    static func show(
        _ error: ScreenshotTranslationError,
        present: (NSAlert) -> NSApplication.ModalResponse,
        authorize: () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = error.localizedDescription
        alert.addButton(withTitle: L10n.text("ok"))
        let response = present(alert)
        if error == .permissionDenied, response == .alertFirstButtonReturn {
            authorize()
        }
    }
}
