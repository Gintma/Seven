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
        var started = XCTestExpectation(description: "开始跟踪授权页")
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

    func testClosingSettingsDiscardsRequestAndCurrentGrantCompletesOnce() async {
        let tracker = Tracker()
        var granted = false
        let guide = PermissionGuide(tracker: tracker, openPane: { _ in true }, isGranted: { _ in granted })
        var completions: [String] = []
        guide.authorize(.accessibility, onGranted: { completions.append("previous") })
        await fulfillment(of: [tracker.started], timeout: 2)
        tracker.onSettingsClosed?()
        XCTAssertFalse(tracker.running)
        XCTAssertTrue(completions.isEmpty)

        tracker.started = XCTestExpectation(description: "跟踪下一次授权")
        guide.authorize(.accessibility, onGranted: { completions.append("current") })
        await fulfillment(of: [tracker.started], timeout: 2)
        granted = true
        tracker.onPoll?()
        tracker.onPoll?()
        guide.close()
        XCTAssertEqual(completions, ["current"])
    }

    func testRefreshCompletesManualGrantWhenOpeningSettingsFailed() async {
        let tracker = Tracker()
        let triedOpening = expectation(description: "尝试打开系统设置")
        var granted = false
        let guide = PermissionGuide(tracker: tracker, openPane: { _ in
            triedOpening.fulfill()
            return false
        }, isGranted: { _ in granted })
        var completions = 0
        guide.authorize(.accessibility, onGranted: { completions += 1 })
        await fulfillment(of: [triedOpening], timeout: 2)
        XCTAssertFalse(tracker.running)
        guide.refreshPermission()
        XCTAssertEqual(completions, 0)

        granted = true
        guide.refreshPermission()
        guide.refreshPermission()
        XCTAssertEqual(completions, 1)
    }
}
