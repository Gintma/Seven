import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Seven

@MainActor
final class HistoryStoreTests: XCTestCase {
    func testClosedHistoryDoesNotRedecodeLargeSnapshotOnConsecutiveWrites() throws {
        try withHistoryDirectory { directory, defaults in
            let url = directory.appendingPathComponent("history.json")
            let fixture = HistoryStore(fileURL: url, defaults: defaults)
            fixture.add(sourceText: String(repeating: "a", count: 8 * 1_024 * 1_024), translatedText: "large",
                        sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translate)
            var reads = 0
            let store = HistoryStore(fileURL: url, defaults: defaults, readData: { url in
                reads += 1
                return try Data(contentsOf: url, options: .mappedIfSafe)
            })
            store.setBrowsing(true)
            XCTAssertEqual(store.records.count, 1)
            XCTAssertEqual(reads, 1)
            var refreshes = 0
            // 模拟已关闭但保留的托管视图消费 revision，并从一次布局的多个位置读取记录。
            let observer = store.$revision.dropFirst().sink { [weak store] _ in
                refreshes += 1
                _ = store?.records
                _ = store?.records
                _ = store?.records
            }
            defer { observer.cancel() }
            store.setBrowsing(false)
            for source in ["first", "second"] {
                store.add(sourceText: source, translatedText: "result",
                          sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translate)
            }
            XCTAssertEqual(refreshes, 0, "隐藏窗口不应随翻译写入刷新")
            XCTAssertEqual(reads, 1, "连续两次写入均应复用窗口关闭时的快照")
            store.setBrowsing(true)
            XCTAssertEqual(refreshes, 1, "重开只通知一次并显示关闭期间新增的记录")
            XCTAssertEqual(store.records.prefix(2).map(\.sourceText), ["second", "first"])
            XCTAssertEqual(reads, 1)
        }
    }

    func testHistoryRecoveryWaitsUntilFirstRead() throws {
        try withHistoryDirectory { directory, defaults in
            let url = directory.appendingPathComponent("history.json")
            let original = Data("corrupt fixture".utf8)
            try original.write(to: url)
            let store = HistoryStore(fileURL: url, defaults: defaults)
            XCTAssertEqual(try? Data(contentsOf: url), original)
            XCTAssertTrue(store.records.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testExpiredLargeHistoryDoesNotReloadUntilFirstWriteAndReusesTheResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try XCTUnwrap(isolatedDefaults())
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        var reads = 0
        let store = HistoryStore(fileURL: url, defaults: defaults, idleSnapshotLifetime: .milliseconds(20), readData: { url in
            reads += 1
            return try Data(contentsOf: url, options: .mappedIfSafe)
        })
        store.setBrowsing(true)
        store.add(sourceText: String(repeating: "a", count: 8 * 1_024 * 1_024), translatedText: "one",
                  sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translate)
        XCTAssertEqual(store.browsingRecords.count, 1)
        XCTAssertTrue(try Data(contentsOf: url).count > 8 * 1_024 * 1_024)
        store.setBrowsing(false)
        XCTAssertEqual(store.browsingRecords.count, 1, "关闭后的短时间内应保留快照")
        let readsBeforeIdle = reads
        for _ in 0..<100 where !store.browsingRecords.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(store.browsingRecords.isEmpty, "空闲时应释放超预算快照")
        XCTAssertEqual(reads, readsBeforeIdle, "隐藏视图的读访问不应重载文件")
        for source in ["first", "second"] {
            store.add(sourceText: source, translatedText: "result",
                      sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translate)
        }
        XCTAssertEqual(reads, readsBeforeIdle + 1, "过期后只应解码一次，连续写入继续复用")
        store.setBrowsing(true)
        XCTAssertEqual(store.browsingRecords.prefix(2).map(\.sourceText), ["second", "first"])
        XCTAssertEqual(store.browsingRecords.count, 3)
        XCTAssertEqual(reads, readsBeforeIdle + 1, "重开应使用刚写入的快照")
    }

    func testHistoryPersistsDeduplicatesAndFavorites() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenTests.\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("history.json")
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = HistoryStore(fileURL: fileURL, defaults: defaults)

        store.add(
            sourceText: "Hello", translatedText: "你好",
            sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translate
        )
        store.add(
            sourceText: "Hello", translatedText: "你好",
            sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translate
        )

        XCTAssertEqual(store.records.count, 1)
        let id = try XCTUnwrap(store.records.first?.id)
        store.toggleFavorite(id)
        XCTAssertTrue(store.records[0].isFavorite)

        let reloaded = HistoryStore(fileURL: fileURL, defaults: defaults)
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertTrue(reloaded.records[0].isFavorite)
    }

    func testHistoryRespectsDisabledSettingAndExports() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenTests.\(UUID().uuidString)", isDirectory: true)
        let historyURL = directory.appendingPathComponent("history.json")
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = HistoryStore(fileURL: historyURL, defaults: defaults)
        store.isEnabled = false
        store.add(
            sourceText: "Ignored", translatedText: "忽略",
            sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translate
        )
        XCTAssertTrue(store.records.isEmpty)

        store.isEnabled = true
        store.add(
            sourceText: "Hello", translatedText: "你好",
            sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translate
        )
        let markdownURL = directory.appendingPathComponent("export.md")
        let jsonURL = directory.appendingPathComponent("export.json")
        try store.export(store.records, to: markdownURL, format: .markdown)
        try store.export(store.records, to: jsonURL, format: .json)

        XCTAssertTrue(try String(contentsOf: markdownURL).contains("你好"))
        XCTAssertFalse(try Data(contentsOf: jsonURL).isEmpty)
    }
    func testCorruptHistoryIsBackedUpBeforeNextTranslation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.json")
        let original = Data("[{\"sourceText\":\"private fixture\", broken".utf8)
        try original.write(to: url)
        let store = HistoryStore(fileURL: url, defaults: defaults)
        XCTAssertTrue(store.records.isEmpty)
        store.add(sourceText: "New", translatedText: "新", sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translate)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("history.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        let reloaded = HistoryStore(fileURL: url, defaults: defaults)
        XCTAssertEqual(reloaded.records.first?.sourceText, "New")
    }

    func testHistoryExportFailureAlertDoesNotExposeRecordText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = HistoryStore(fileURL: directory.appendingPathComponent("history.json"), defaults: defaults)
        store.add(sourceText: "PRIVATE SOURCE", translatedText: "PRIVATE TRANSLATION", sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translate)
        let view = HistoryView(store: store)
        for format in [HistoryExportFormat.json, .markdown] {
            var alert: NSAlert?
            view.export(to: directory.appendingPathComponent("missing/export"), format: format) { alert = $0 }
            let presented = try XCTUnwrap(alert)
            XCTAssertFalse(presented.informativeText.contains("PRIVATE"))
        }
    }

    func testCorruptBackupsAreBoundedAndNewestContentSurvives() throws {
        try withHistoryDirectory { directory, defaults in
            let url = directory.appendingPathComponent("history.json")
            for index in 0..<8 {
                try Data("corrupt-\(index)".utf8).write(to: url)
                XCTAssertTrue(HistoryStore(fileURL: url, defaults: defaults).records.isEmpty)
            }
            let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("history.corrupt-") }
            XCTAssertEqual(backups.count, 5)
            let contents = try backups.map { try String(contentsOf: $0) }.sorted()
            XCTAssertEqual(contents, (3..<8).map { "corrupt-\($0)" })
        }
    }

    func testMissingHistoryStartsEmptyWithoutBackup() throws {
        try withHistoryDirectory { directory, defaults in
            let store = HistoryStore(fileURL: directory.appendingPathComponent("history.json"), defaults: defaults)
            XCTAssertTrue(store.records.isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    func testUnreadableHistoryIsPreserved() throws {
        try withHistoryDirectory { directory, defaults in
            let url = directory.appendingPathComponent("history.json")
            let original = Data("unreadable fixture".utf8)
            try original.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            let store = HistoryStore(fileURL: url, defaults: defaults)
            store.add(sourceText: "New", translatedText: "新", sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translate)
            let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("history.corrupt-") })
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            XCTAssertEqual(try Data(contentsOf: backup), original)
        }
    }

    func testFailedQuarantineUsesRecoveryFileAndReloadsIt() throws {
        try withHistoryDirectory { directory, defaults in
            let url = directory.appendingPathComponent("history.json")
            let original = Data("corrupt fixture".utf8)
            try original.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
            let store = HistoryStore(fileURL: url, defaults: defaults)
            XCTAssertTrue(store.records.isEmpty)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            store.add(sourceText: "Recovered", translatedText: "恢复", sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translate)
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.recovery.json").path))
            let reloaded = HistoryStore(fileURL: url, defaults: defaults)
            XCTAssertEqual(reloaded.records.first?.sourceText, "Recovered")
        }
    }

    func testBothQuarantinesFailWithoutOverwritingEitherFile() throws {
        try withHistoryDirectory { directory, defaults in
            let url = directory.appendingPathComponent("history.json")
            let recovery = directory.appendingPathComponent("history.recovery.json")
            try Data("original".utf8).write(to: url)
            try Data("recovery".utf8).write(to: recovery)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
            let store = HistoryStore(fileURL: url, defaults: defaults)
            XCTAssertTrue(store.records.isEmpty)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            store.add(sourceText: "New", translatedText: "新", sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translate)
            XCTAssertEqual(try String(contentsOf: url), "original")
            XCTAssertEqual(try String(contentsOf: recovery), "recovery")
            XCTAssertTrue(try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        }
    }

    func testCorruptLoadDiagnosticContainsOnlyEventAndErrorType() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.json")
        try Data("PRIVATE HISTORY".utf8).write(to: url)
        let recorded = expectation(description: "load diagnostic recorded")
        let logger = HistoryTestLogger(recorded: recorded)
        XCTAssertTrue(HistoryStore(fileURL: url, defaults: defaults, logger: logger).records.isEmpty)
        await fulfillment(of: [recorded], timeout: 2)
        let events = await logger.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.0, "history_load_failed")
        XCTAssertEqual(events.first?.1, ["errorType": "DecodingError"])
    }

    func testHealthyAndMissingHistoryDoNotResolveDiagnosticLogger() throws {
        try withHistoryDirectory { directory, defaults in
            let healthyURL = directory.appendingPathComponent("history.json")
            try Data("[]".utf8).write(to: healthyURL)
            var resolutions = 0
            let resolveLogger = { () -> DiagnosticLogging in
                resolutions += 1
                return NoopDiagnosticLogger()
            }
            let healthy = HistoryStore(fileURL: healthyURL, defaults: defaults, logger: resolveLogger())
            XCTAssertTrue(healthy.records.isEmpty)
            XCTAssertEqual(resolutions, 0, "Healthy history must not resolve a logger")
            let missing = HistoryStore(fileURL: directory.appendingPathComponent("missing.json"), defaults: defaults,
                                       logger: resolveLogger())
            XCTAssertTrue(missing.records.isEmpty)
            XCTAssertEqual(resolutions, 0, "Missing history must not resolve a logger")
        }
    }

    private func withHistoryDirectory(_ body: (URL, UserDefaults) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        try body(directory, defaults)
    }

}

private actor HistoryTestLogger: DiagnosticLogging {
    nonisolated let fileURL = URL(fileURLWithPath: "/dev/null")
    private let recorded: XCTestExpectation
    private(set) var events: [(String, [String: String])] = []

    init(recorded: XCTestExpectation) { self.recorded = recorded }
    func record(_ level: DiagnosticLevel, _ event: String, metadata: [String: String]) async {
        events.append((event, metadata))
        recorded.fulfill()
    }
    func contents() async -> String { "" }
    func clear() async {}
}

extension HistoryStoreTests {
    func testHistoryWindowLoadsCurrentRecordsLazilyAndReusesItsContent() throws {
        _ = NSApplication.shared
        try withHistoryDirectory { directory, defaults in
            let store = HistoryStore(fileURL: directory.appendingPathComponent("history.json"), defaults: defaults)
            let controller = HistoryWindowController(store: store)
            XCTAssertFalse(controller.isWindowLoaded)
            store.add(sourceText: "输入", translatedText: "Result", sourceLanguage: "zh-Hans", targetLanguage: "en", mode: .translate)
            controller.showWindow(nil)
            let window = try XCTUnwrap(controller.window)
            defer { controller.close() }
            let host = try XCTUnwrap(window.contentView as? NSHostingView<HistoryView>)
            XCTAssertTrue(host.rootView.store === store)
            XCTAssertEqual(host.rootView.store.records.map(\.translatedText), ["Result"])
            controller.close()
            controller.showWindow(nil)
            XCTAssertTrue(controller.window === window)
            XCTAssertTrue(window.contentView === host)
        }
    }
}
