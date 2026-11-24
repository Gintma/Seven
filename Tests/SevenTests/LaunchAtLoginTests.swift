import XCTest
import ServiceManagement
@testable import Seven

private final class MemoryLaunchAtLoginService: LaunchAtLoginServicing {
    var state: LaunchAtLoginState = .disabled
    var error: Error?

    func setEnabled(_ enabled: Bool) throws {
        if let error { throw error }
        guard state != .unavailable else { return }
        state = enabled ? .enabled : .disabled
    }
}

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    func testNotFoundMainAppStillRegistersAndCanUnregister() throws {
        final class FreshRegistration: MainAppLoginRegistering {
            var status = SMAppService.Status.notFound
            func register() throws { status = .enabled }
            func unregister() throws { status = .notRegistered }
        }
        let system = FreshRegistration()
        let service = SystemLaunchAtLoginService(service: system)
        XCTAssertEqual(service.state, .disabled)
        try service.setEnabled(true)
        XCTAssertEqual(system.status, .enabled)
        try service.setEnabled(false)
        XCTAssertEqual(system.status, .notRegistered)
    }

    func testControllerEnablesAndDisablesService() {
        let service = MemoryLaunchAtLoginService()
        let controller = LaunchAtLoginController(service: service, logger: NoopDiagnosticLogger())

        controller.setEnabled(true)
        XCTAssertTrue(controller.enabled)
        XCTAssertEqual(controller.state, .enabled)

        controller.setEnabled(false)
        XCTAssertFalse(controller.enabled)
        XCTAssertEqual(controller.state, .disabled)
    }

    func testControllerSurfacesRegistrationFailure() {
        let service = MemoryLaunchAtLoginService()
        service.error = TranslationError.configuration("registration failed")
        let controller = LaunchAtLoginController(service: service, logger: NoopDiagnosticLogger())

        controller.setEnabled(true)

        XCTAssertFalse(controller.enabled)
        XCTAssertTrue(controller.message?.contains("registration failed") == true)
    }

    func testUnknownServiceStatusReportsAnUnavailableLoginItem() {
        let service = MemoryLaunchAtLoginService()
        service.state = .unavailable
        let controller = LaunchAtLoginController(service: service, logger: NoopDiagnosticLogger())
        XCTAssertEqual(controller.message, L10n.text("loginItemStatusUnavailable"))
        controller.refresh()
        controller.setEnabled(true)
        XCTAssertFalse(controller.enabled)
        XCTAssertEqual(controller.state, .unavailable)
        XCTAssertEqual(controller.message, L10n.text("loginItemStatusUnavailable"))
    }

    func testRefreshClearsUnavailableMessageAfterRecovery() {
        for recoveredState in [LaunchAtLoginState.enabled, .disabled] {
            let service = MemoryLaunchAtLoginService()
            service.state = .unavailable
            let controller = LaunchAtLoginController(service: service, logger: NoopDiagnosticLogger())
            XCTAssertNotNil(controller.message)

            service.state = recoveredState
            controller.refresh()

            XCTAssertEqual(controller.state, recoveredState)
            XCTAssertEqual(controller.enabled, recoveredState == .enabled)
            XCTAssertNil(controller.message)
        }
    }

}
