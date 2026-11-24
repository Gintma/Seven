import XCTest
@testable import Seven

final class DevelopmentDiagnosticsTests: XCTestCase {
    func testBuildChannelControlsNavigationAndTraceOptIn() throws {
#if DEBUG || SEVEN_DEVELOPMENT
        let expected = true
#else
        let expected = false
#endif
        XCTAssertEqual(SettingsNavigationGroup.general.sections.contains { $0.rawValue == "diagnostics" }, expected,
                       "开发变体即便使用 Release 优化也应显示诊断，正式发布才隐藏")
        XCTAssertEqual(SettingsSection.allCases.contains { $0.rawValue == "diagnostics" }, expected)
        let suite = "SevenTests.DevelopmentDiagnostics.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let scroll = directory.appendingPathComponent("scroll")
        XCTAssertNil(ScreenshotScrollTrace.start(defaults: defaults, directory: scroll))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        defaults.set(true, forKey: ScreenshotScrollTrace.enabledKey)
        XCTAssertEqual(ScreenshotScrollTrace.start(defaults: defaults, directory: scroll) != nil, expected)
        XCTAssertEqual(FileManager.default.fileExists(atPath: directory.path), expected,
                       "正式包即使偏好中残留开启值，也不能创建诊断文件")
    }
}
