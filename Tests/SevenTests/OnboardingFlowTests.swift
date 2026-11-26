import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Seven

final class OnboardingFlowTests: XCTestCase {
    @MainActor func testFreshInstallShowsOnboarding() throws {
        let fixture = try Fixture(test: self)
        try FileManager.default.createDirectory(
            at: fixture.dataDirectory.appendingPathComponent("BuildSigning"), withIntermediateDirectories: false
        )

        let registrationDomain = UserDefaults.registrationDomain
        let registered = fixture.defaults.volatileDomain(forName: registrationDomain)
        fixture.defaults.register(defaults: ["configured": false])
        let flow = fixture.makeFlow()
        // 注册域在测试进程内共享，读取引导状态后恢复。
        fixture.defaults.removeVolatileDomain(forName: registrationDomain)
        fixture.defaults.setVolatileDomain(registered, forName: registrationDomain)
        _ = SettingsStore(defaults: fixture.defaults).migrateServiceInstances()

        XCTAssertTrue(flow.shouldShow(hasPendingImages: false))
        XCTAssertEqual(fixture.status, "pending")
    }

    @MainActor func testExistingConfigurationIsSilentlyMarkedComplete() throws {
        let fixture = try Fixture(test: self)
        let settings = SettingsStore(defaults: fixture.defaults)
        settings.configured = false

        XCTAssertFalse(fixture.makeFlow().shouldShow(hasPendingImages: false))
        XCTAssertEqual(fixture.status, "completed")
        XCTAssertEqual(settings.migrateServiceInstances().filter(\.enabled).map(\.provider), [.apple])
    }

    @MainActor func testClearedServiceListStillCountsAsExistingUsage() throws {
        let fixture = try Fixture(test: self)
        SettingsStore(defaults: fixture.defaults).serviceInstances = []

        XCTAssertFalse(fixture.makeFlow().shouldShow(hasPendingImages: false))
        XCTAssertEqual(fixture.status, "completed")
    }

    @MainActor func testExistingHistoryIsSilentlyMarkedComplete() throws {
        let fixture = try Fixture(test: self)
        try Data("[]".utf8).write(to: fixture.dataDirectory.appendingPathComponent("history.json"))

        XCTAssertFalse(fixture.makeFlow().shouldShow(hasPendingImages: false))
        XCTAssertEqual(fixture.status, "completed")
    }

    @MainActor func testRestartBeforeCompletionContinuesAfterStartupWritesDefaults() throws {
        let fixture = try Fixture(test: self)
        XCTAssertTrue(fixture.makeFlow().shouldShow(hasPendingImages: false))
        _ = SettingsStore(defaults: fixture.defaults).migrateServiceInstances()

        XCTAssertTrue(fixture.makeFlow().shouldShow(hasPendingImages: false))
        XCTAssertEqual(fixture.status, "pending")
    }

    @MainActor func testStartCompletesThenClosesAndOpensInputOnce() throws {
        let fixture = try Fixture(test: self)
        let flow = fixture.makeFlow()
        XCTAssertTrue(flow.shouldShow(hasPendingImages: false))
        var events: [String] = []

        flow.finish(.start, close: {
            XCTAssertEqual(fixture.status, "completed")
            events.append("close")
        }, openInput: {
            events.append("input")
        })
        flow.finish(.start, close: { XCTFail("已经关闭") }, openInput: { XCTFail("已经打开输入翻译") })

        XCTAssertEqual(events, ["close", "input"])
        XCTAssertFalse(fixture.makeFlow().shouldShow(hasPendingImages: false))
    }

    @MainActor func testDismissViaCloseOrEscapeCompletesWithoutOpeningInput() throws {
        let fixture = try Fixture(test: self)
        let flow = fixture.makeFlow()
        XCTAssertTrue(flow.shouldShow(hasPendingImages: false))

        flow.finish(.dismiss, close: {}, openInput: { XCTFail("关闭引导不应打开输入翻译") })

        XCTAssertEqual(fixture.status, "completed")
        XCTAssertFalse(fixture.makeFlow().shouldShow(hasPendingImages: false))
    }

    @MainActor func testEscapeRequestsNativeCloseWithNoFocusedControl() throws {
        _ = NSApplication.shared
        let window = OnboardingWindowController.makeWindow()
        window.isReleasedWhenClosed = false
        let delegate = CloseRecorder()
        window.delegate = delegate
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: UInt16(kVK_Escape)
        ))

        window.sendEvent(escape)

        XCTAssertEqual(delegate.closeRequests, 1)
    }

    @MainActor
    private final class CloseRecorder: NSObject, NSWindowDelegate {
        private(set) var closeRequests = 0

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            closeRequests += 1
            return false
        }
    }

    @MainActor func testColdImageLaunchDefersFreshOnboardingWithoutCompletingIt() throws {
        let fixture = try Fixture(test: self)
        XCTAssertFalse(fixture.makeFlow().shouldShow(hasPendingImages: true))
        XCTAssertEqual(fixture.status, "pending")
        _ = SettingsStore(defaults: fixture.defaults).migrateServiceInstances()

        XCTAssertFalse(fixture.makeFlow().shouldShow(hasPendingImages: true))
        XCTAssertTrue(fixture.makeFlow().shouldShow(hasPendingImages: false))
        XCTAssertEqual(fixture.status, "pending")
    }

    @MainActor func testColdImageLaunchDoesNotMarkExistingInstallCompleteUntilNormalLaunch() throws {
        let fixture = try Fixture(test: self)
        SettingsStore(defaults: fixture.defaults).primaryLanguage = "en"

        XCTAssertFalse(fixture.makeFlow().shouldShow(hasPendingImages: true))
        XCTAssertNil(fixture.status)
        XCTAssertFalse(fixture.makeFlow().shouldShow(hasPendingImages: false))
        XCTAssertEqual(fixture.status, "completed")
    }

    @MainActor func testSuccessReactionsResumeOnceAndWaitForApproval() throws {
        let fixture = try Fixture(test: self)
        let initial = fixture.makeFlow()
        XCTAssertTrue(initial.shouldShow(hasPendingImages: false))
        XCTAssertNil(initial.nextReaction(accessibility: true, screenRecording: true, login: .enabled))
        initial.awaitSuccess(.screenRecording)
        initial.awaitSuccess(.login)
        let resumed = fixture.makeFlow()
        XCTAssertNil(resumed.nextReaction(accessibility: true, screenRecording: false, login: .requiresApproval))
        XCTAssertEqual(resumed.nextReaction(accessibility: true, screenRecording: true, login: .requiresApproval), .screenRecording)
        XCTAssertNil(resumed.nextReaction(accessibility: true, screenRecording: true, login: .requiresApproval))
        XCTAssertEqual(resumed.nextReaction(accessibility: true, screenRecording: true, login: .enabled), .login)
        XCTAssertNil(resumed.nextReaction(accessibility: true, screenRecording: true, login: .enabled))
        resumed.awaitSuccess(.accessibility)
        resumed.finish(.dismiss, close: {}, openInput: {})
        XCTAssertNil(fixture.makeFlow().nextReaction(accessibility: true, screenRecording: true, login: .enabled))
    }

    private struct Fixture {
        let defaults: UserDefaults
        let dataDirectory: URL
        let suiteName: String

        init(test: XCTestCase) throws {
            suiteName = "SevenTests.Onboarding." + UUID().uuidString
            defaults = try XCTUnwrap(test.isolatedDefaults(suiteName: suiteName))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            test.addTeardownBlock { try FileManager.default.removeItem(at: directory) }
            dataDirectory = directory
        }

        @MainActor var status: String? { defaults.string(forKey: OnboardingFlow.storageKey) }

        @MainActor func makeFlow() -> OnboardingFlow {
            OnboardingFlow(defaults: defaults, hasExistingUsage: OnboardingFlow.hasExistingUsage(
                preferences: defaults.persistentDomain(forName: suiteName) ?? [:],
                dataDirectory: dataDirectory
            ))
        }
    }
}
