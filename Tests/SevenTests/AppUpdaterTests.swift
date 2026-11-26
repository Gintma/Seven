import AppKit
import XCTest
@testable import Seven

@MainActor
final class AppUpdaterTests: XCTestCase {
    nonisolated private static let appIdentifier = "com.crissun.seven"
    nonisolated private static let feed = "https://example.test/appcast.xml"
    nonisolated private static let publicKey = Data(1...32).base64EncodedString()

    private func configuration(identifier: String? = appIdentifier, development: Bool = false,
                               version: String? = "1.2.3", feed: String? = feed, key: String? = publicKey) -> AppUpdateConfiguration {
        AppUpdateConfiguration(bundleIdentifier: identifier, isDevelopmentBuild: development,
                               version: version, feed: feed, publicKey: key)
    }

    func testIneligibleBuildsNeverCreateOrStartSparkle() throws {
        try withDefaults { defaults in
            let cases: [(AppUpdateConfiguration, AppUpdateConfiguration.Availability)] = [
                (configuration(development: true), .development),
                (configuration(identifier: "com.crissun.seven.sparkle"), .development),
                (configuration(identifier: nil), .development),
                (configuration(key: nil), .unconfigured),
                (configuration(key: "REPLACE_WITH_SPARKLE_ED25519_PUBLIC_KEY"), .unconfigured),
                (configuration(key: Data(repeating: 0, count: 32).base64EncodedString()), .unconfigured),
                (configuration(feed: nil), .unconfigured),
                (configuration(feed: "http://example.test/appcast.xml"), .unconfigured)
            ]
            for (configuration, expected) in cases {
                let updater = AppUpdater(defaults: defaults, configuration: configuration) {
                    XCTFail("Ineligible builds must not create Sparkle")
                    return MockUpdateBackend()
                }
                updater.automaticChecksEnabled = false
                updater.automaticDownloadsEnabled = true
                updater.checkForUpdates()
                XCTAssertEqual(updater.availability, expected)
                XCTAssertFalse(updater.canCheckForUpdates)
                XCTAssertFalse(updater.isChecking)
                XCTAssertFalse(updater.showsUpdateShortcut)
            }
        }
    }

    func testPreflightFailureKeepsUpdaterUnavailable() throws {
        try withDefaults { defaults in
            let backend = MockUpdateBackend()
            backend.startError = CocoaError(.featureUnsupported)
            let updater = AppUpdater(defaults: defaults, configuration: configuration()) { backend }

            XCTAssertEqual(updater.availability, .unconfigured)
            XCTAssertFalse(updater.canCheckForUpdates)
            updater.checkForUpdates()
            XCTAssertEqual(backend.checks, 0)
        }
    }

    func testFreshInstallChecksAutomaticallyWithoutDownloading() throws {
        try withDefaults { defaults in
            let backend = MockUpdateBackend()
            _ = AppUpdater(defaults: defaults, configuration: configuration()) { backend }

            XCTAssertTrue(backend.checksEnabledAtStart)
            XCTAssertFalse(backend.downloadsEnabledAtStart)
        }
    }

    func testAutomaticPreferencesPersistAndSynchronizeIndependently() throws {
        try withDefaults { defaults in
            let backend = MockUpdateBackend()
            let updater = AppUpdater(defaults: defaults, configuration: configuration()) { backend }
            XCTAssertTrue(backend.checksEnabledAtStart)
            XCTAssertFalse(backend.downloadsEnabledAtStart)

            updater.automaticDownloadsEnabled = true
            updater.updateButtonEnabled = false
            XCTAssertTrue(backend.automaticallyChecksForUpdates)
            XCTAssertTrue(backend.automaticallyDownloadsUpdates)

            let nextBackend = MockUpdateBackend()
            let reopened = AppUpdater(defaults: defaults, configuration: configuration()) { nextBackend }
            XCTAssertTrue(nextBackend.checksEnabledAtStart)
            XCTAssertTrue(nextBackend.downloadsEnabledAtStart)
            XCTAssertFalse(reopened.updateButtonEnabled)

            nextBackend.automaticallyDownloadsUpdates = false
            nextBackend.onChange?(.automaticDownloadsChanged(false))
            XCTAssertFalse(reopened.automaticDownloadsEnabled)
            XCTAssertTrue(reopened.automaticChecksEnabled)
            XCTAssertTrue(nextBackend.automaticallyChecksForUpdates)
            XCTAssertFalse(nextBackend.automaticallyDownloadsUpdates)

            reopened.automaticDownloadsEnabled = true
            reopened.automaticChecksEnabled = false
            XCTAssertFalse(nextBackend.automaticallyChecksForUpdates)
            XCTAssertTrue(nextBackend.automaticallyDownloadsUpdates)
            reopened.checkForUpdates()
            XCTAssertEqual(nextBackend.checks, 1)

            let finalBackend = MockUpdateBackend()
            let finalUpdater = AppUpdater(defaults: defaults, configuration: configuration()) { finalBackend }
            XCTAssertFalse(finalUpdater.automaticChecksEnabled)
            XCTAssertTrue(finalUpdater.automaticDownloadsEnabled)
            XCTAssertFalse(finalBackend.checksEnabledAtStart)
            XCTAssertTrue(finalBackend.downloadsEnabledAtStart)
        }
    }

    func testLegacyAutomaticPreferenceMigratesOnceToBothSettings() throws {
        let legacyKey = "updates.automatic.v1"
        for enabled in [false, true] {
            try withDefaults { defaults in
                defaults.set(enabled, forKey: legacyKey)
                let backend = MockUpdateBackend()
                _ = AppUpdater(defaults: defaults, configuration: configuration()) { backend }
                XCTAssertEqual(backend.checksEnabledAtStart, enabled)
                XCTAssertEqual(backend.downloadsEnabledAtStart, enabled)

                defaults.set(!enabled, forKey: legacyKey)
                let nextBackend = MockUpdateBackend()
                _ = AppUpdater(defaults: defaults, configuration: configuration()) { nextBackend }
                XCTAssertEqual(nextBackend.checksEnabledAtStart, enabled)
                XCTAssertEqual(nextBackend.downloadsEnabledAtStart, enabled)
            }
        }
    }

    func testManualCheckAndInstallShortcutFollowUpdaterState() throws {
        try withDefaults { defaults in
            let backend = MockUpdateBackend()
            let updater = AppUpdater(defaults: defaults, configuration: configuration()) { backend }
            XCTAssertTrue(updater.canCheckForUpdates)
            XCTAssertFalse(updater.showsUpdateShortcut)
            updater.installAvailableUpdate()
            XCTAssertEqual(backend.checks, 0)

            updater.checkForUpdates()
            XCTAssertTrue(updater.isChecking)
            updater.checkForUpdates()
            XCTAssertEqual(backend.checks, 1)

            backend.onChange?(.updateAvailable(true))
            XCTAssertTrue(updater.showsUpdateShortcut)
            updater.installAvailableUpdate()
            XCTAssertEqual(backend.checks, 1)
            backend.allowChecks()
            XCTAssertFalse(updater.isChecking)

            updater.updateButtonEnabled = false
            XCTAssertFalse(updater.showsUpdateShortcut)
            updater.installAvailableUpdate()
            XCTAssertEqual(backend.checks, 1)

            updater.updateButtonEnabled = true
            XCTAssertTrue(updater.showsUpdateShortcut)
            updater.installAvailableUpdate()
            XCTAssertEqual(backend.checks, 2)
            backend.onChange?(.updateAvailable(false))
            backend.allowChecks()
            XCTAssertFalse(updater.showsUpdateShortcut)
            XCTAssertFalse(updater.isChecking)
        }
    }

    func testAppStatusMenuUsesTheSameAvailabilityAndAction() throws {
        try withDefaults { defaults in
            let backend = MockUpdateBackend()
            let updater = AppUpdater(defaults: defaults, configuration: configuration()) { backend }
            let target = UpdateMenuTarget(updater: updater)
            try L10n.$languageOverride.withValue(.english) {
                let menu = AppStatusMenu.build(translation: [], screenshots: [], ocr: [], settings: NSMenuItem(),
                                               updater: updater, target: target)
                let item = try XCTUnwrap(menu.items.first { $0.title == L10n.text("about.updateAvailable") })
                XCTAssertTrue(item.isHidden)

                backend.onChange?(.updateAvailable(true))
                AppStatusMenu.refreshUpdateShortcut(in: menu, updater: updater)
                XCTAssertFalse(item.isHidden)
                let action = try XCTUnwrap(item.action)
                XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))
                XCTAssertEqual(backend.checks, 1)

                AppStatusMenu.refreshUpdateShortcut(in: menu, updater: updater)
                XCTAssertNil(item.action)
                updater.updateButtonEnabled = false
                AppStatusMenu.refreshUpdateShortcut(in: menu, updater: updater)
                XCTAssertTrue(item.isHidden)
            }
        }
    }

    func testReleaseNotesUseVersionTagOnlyForReleaseBuilds() {
        let releases = "https://github.com/crismakes/Seven/releases"
        XCTAssertEqual(configuration().releaseNotesURL.absoluteString, releases + "/tag/v1.2.3")
        XCTAssertEqual(configuration(development: true).releaseNotesURL.absoluteString, releases)
        XCTAssertEqual(configuration(identifier: "com.crissun.seven.sparkle").releaseNotesURL.absoluteString, releases)
        XCTAssertEqual(configuration(version: nil).releaseNotesURL.absoluteString, releases)
    }

    private func withDefaults(_ run: (UserDefaults) throws -> Void) throws {
        let suite = "SevenTests.AppUpdater." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try run(defaults)
    }
}

@MainActor
private final class MockUpdateBackend: AppUpdateBackend {
    var canCheckForUpdates = false
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    var onChange: ((AppUpdateEvent) -> Void)?
    var startError: Error?
    private(set) var checks = 0
    private(set) var checksEnabledAtStart = false
    private(set) var downloadsEnabledAtStart = false

    func start() throws {
        if let startError { throw startError }
        checksEnabledAtStart = automaticallyChecksForUpdates
        downloadsEnabledAtStart = automaticallyDownloadsUpdates
        canCheckForUpdates = true
    }

    func checkForUpdates() {
        checks += 1
        canCheckForUpdates = false
        onChange?(.canCheck(false))
    }

    func allowChecks() {
        canCheckForUpdates = true
        onChange?(.canCheck(true))
    }
}

@MainActor
private final class UpdateMenuTarget: NSObject {
    let updater: AppUpdater

    init(updater: AppUpdater) { self.updater = updater }

    @objc func checkForSevenUpdates() { updater.installAvailableUpdate() }
}
