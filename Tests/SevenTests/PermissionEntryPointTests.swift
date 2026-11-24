import Foundation
import XCTest

final class PermissionEntryPointTests: XCTestCase {
    func testPermissionRequestsCannotBypassSharedGuide() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Seven")
        var bypasses: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            if file.lastPathComponent != "PermissionGuide.swift",
               source.contains("Privacy_Accessibility") || source.contains("Privacy_ScreenCapture") {
                bypasses.append(file.lastPathComponent)
            }
            if source.contains("AXIsProcessTrustedWithOptions(") || source.contains("CGRequestScreenCaptureAccess(") {
                bypasses.append(file.lastPathComponent)
            }
        }
        XCTAssertTrue(bypasses.isEmpty, "授权入口应统一使用 PermissionGuide：" + bypasses.joined(separator: "、"))
    }
}
