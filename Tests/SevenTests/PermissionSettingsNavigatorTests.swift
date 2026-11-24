import AppKit
import XCTest
@testable import Seven

@MainActor
final class PermissionSettingsNavigatorTests: XCTestCase {
    func testLaunchesSettingsBeforeOpeningPaneAndThenActivatesItsWindows() async throws {
        let workspace = RecordingSettingsWorkspace()
        let url = try XCTUnwrap(PermissionGuide.Permission.accessibility.settingsURL)
        let opened = await PermissionSettingsNavigator(workspace: workspace).open(url)

        XCTAssertTrue(opened)
        XCTAssertEqual(workspace.events, ["launch", "pane:Privacy_Accessibility", "activate"])
    }

    func testFailedLaunchDoesNotShowSuccessfulGuidance() async throws {
        let workspace = RecordingSettingsWorkspace()
        workspace.launchFails = true
        let url = try XCTUnwrap(PermissionGuide.Permission.screenRecording.settingsURL)
        let opened = await PermissionSettingsNavigator(workspace: workspace).open(url)

        XCTAssertFalse(opened)
        XCTAssertEqual(workspace.events, ["launch"])
    }

    func testScreenRecordingPaneIsOpenedAfterLaunch() async throws {
        let workspace = RecordingSettingsWorkspace()
        let url = try XCTUnwrap(PermissionGuide.Permission.screenRecording.settingsURL)
        let opened = await PermissionSettingsNavigator(workspace: workspace).open(url)

        XCTAssertTrue(opened)
        XCTAssertEqual(workspace.events, ["launch", "pane:Privacy_ScreenCapture", "activate"])
    }
}

@MainActor
private final class RecordingSettingsWorkspace: PermissionSettingsOpening {
    var events: [String] = []
    var launchFails = false

    func launchSettings() async throws {
        events.append("launch")
        if launchFails { throw CocoaError(.fileNoSuchFile) }
    }

    func openPane(_ url: URL) -> Bool {
        events.append("pane:" + (url.query ?? ""))
        return true
    }

    func activateSettings() {
        events.append("activate")
    }
}
