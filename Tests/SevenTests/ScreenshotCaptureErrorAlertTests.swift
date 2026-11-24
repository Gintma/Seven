import AppKit
import XCTest
@testable import Seven

@MainActor
final class ScreenshotCaptureErrorAlertTests: XCTestCase {
    func testConfirmingMissingScreenPermissionOpensGuideAfterDismissal() {
        var events: [String] = []
        ScreenshotCaptureErrorAlert.show(.permissionDenied, present: { alert in
            XCTAssertEqual(alert.messageText, ScreenshotTranslationError.permissionDenied.localizedDescription)
            events.append("dismiss")
            return .alertFirstButtonReturn
        }, authorize: {
            events.append("authorize")
        })
        XCTAssertEqual(events, ["dismiss", "authorize"])
    }

    func testOtherCaptureFailuresOnlyDismissAlert() {
        var authorizations = 0
        ScreenshotCaptureErrorAlert.show(.captureFailed, present: { _ in
            .alertFirstButtonReturn
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
