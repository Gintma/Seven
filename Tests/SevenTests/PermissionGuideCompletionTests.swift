import AppKit
import XCTest
@testable import Seven

@MainActor
final class PermissionGuideCompletionTests: XCTestCase {
    private final class Tracker: PermissionWindowTracking {
        var onFrameChange: ((CGRect) -> Void)?
        var onSettingsClosed: (() -> Void)?
        var onPoll: (() -> Void)?
        var running = false
        let started = XCTestExpectation(description: "开始跟踪授权页")
        func start() { running = true; started.fulfill() }
        func stop() { running = false }
    }

    func testGuideStopsOnActualGrantEvenWhenSettingsFrameNeverChanges() async {
        for requested in [PermissionGuide.Permission.accessibility, .screenRecording] {
            let tracker = Tracker()
            var granted = false
            let guide = PermissionGuide(tracker: tracker, openPane: { _ in true }, isGranted: {
                $0 == requested ? granted : true
            })
            guide.authorize(requested)
            await fulfillment(of: [tracker.started], timeout: 2)
            tracker.onPoll?()
            XCTAssertTrue(tracker.running)
            granted = true
            tracker.onPoll?()
            XCTAssertFalse(tracker.running)
            guide.close()
        }
    }
}
