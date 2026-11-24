import AppKit
import XCTest
@testable import Seven

@MainActor
final class ScreenshotCaptureErrorAlertTests: XCTestCase {
    func testConfirmingMissingScreenPermissionOpensGuideAfterDismissal() {
        var events: [String] = []
        ScreenshotCaptureErrorAlert.show(.permissionDenied, present: { alert in
            XCTAssertEqual(alert.messageText, ScreenshotTranslationError.permissionDenied.localizedDescription)
            XCTAssertEqual(alert.buttons.map(\.title), [L10n.text("openScreenRecordingSettings"), L10n.text("cancel")])
            XCTAssertEqual(alert.buttons.last?.keyEquivalent, "\u{1b}")
            events.append("dismiss")
            return .alertFirstButtonReturn
        }, authorize: {
            events.append("authorize")
        })
        XCTAssertEqual(events, ["dismiss", "authorize"])
    }

    func testOtherCaptureFailuresOnlyDismissAlert() {
        var authorizations = 0
        ScreenshotCaptureErrorAlert.show(.captureFailed, present: { alert in
            XCTAssertEqual(alert.buttons.map(\.title), [L10n.text("ok")])
            return .alertFirstButtonReturn
        }, authorize: {
            authorizations += 1
        })
        XCTAssertEqual(authorizations, 0)
    }

    func testCancellingPermissionAlertDoesNotOpenGuide() {
        var authorizations = 0
        ScreenshotCaptureErrorAlert.show(.permissionDenied, present: { _ in
            .alertSecondButtonReturn
        }, authorize: {
            authorizations += 1
        })
        XCTAssertEqual(authorizations, 0)
    }

    func testAbortedPermissionAlertDoesNotOpenGuide() {
        var authorizations = 0
        ScreenshotCaptureErrorAlert.show(.permissionDenied, present: { _ in
            .abort
        }, authorize: {
            authorizations += 1
        })
        XCTAssertEqual(authorizations, 0)
    }
}
