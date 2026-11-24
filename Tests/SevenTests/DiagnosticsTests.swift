import Foundation
import XCTest
@testable import Seven

final class DiagnosticsTests: XCTestCase {
    func testLoggerWritesMetadataAndCanBeCleared() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = FileDiagnosticLogger(directory: directory)

        await logger.record(.info, "service_test_succeeded", metadata: [
            "host": "api.example.com",
            "elapsed_ms": "120"
        ])

        let contents = await logger.contents()
        XCTAssertTrue(contents.contains("[INFO] service_test_succeeded"))
        XCTAssertTrue(contents.contains("host=api.example.com"))
        XCTAssertTrue(contents.contains("elapsed_ms=120"))

        await logger.clear()
        let clearedContents = await logger.contents()
        XCTAssertEqual(clearedContents, "")
    }

    func testLoggerFlattensNewlines() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = FileDiagnosticLogger(directory: directory)

        await logger.record(.error, "failed\nevent", metadata: ["reason": "line one\nline two"])

        let contents = await logger.contents()
        XCTAssertFalse(contents.contains("failed\nevent"))
        XCTAssertTrue(contents.contains("reason=line one line two"))
    }
}
