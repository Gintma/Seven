import Foundation
import XCTest
@testable import Seven

final class FileCredentialTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Seven-Credentials-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue & 0o777
    }
    func testVariantBundleIdentifierIsolatesDefaultDirectory() throws {
        let home = try temporary()
        let base = home.appendingPathComponent("Library/Application Support/Seven", isDirectory: true)
        let hud = FileCredentialStore.defaultDirectory(homeDirectory: home, bundleIdentifier: "com.crissun.seven.hud")
        let other = FileCredentialStore.defaultDirectory(homeDirectory: home, bundleIdentifier: "com.crissun.seven.test-2")
        XCTAssertEqual(hud, home.appendingPathComponent("Library/Application Support/Seven-hud", isDirectory: true))
        XCTAssertEqual(other, home.appendingPathComponent("Library/Application Support/Seven-test-2", isDirectory: true))
        for identifier in [nil, "com.crissun.seven", "other.app", "com.crissun.seven.",
                           "com.crissun.seven.HUD", "com.crissun.seven.a/b", "com.crissun.seven.a.b"] {
            XCTAssertEqual(FileCredentialStore.defaultDirectory(homeDirectory: home, bundleIdentifier: identifier), base)
        }
        // 只向临时 home 推导的目录注入存储，不接触真实凭据。
        let store = FileCredentialStore(directory: hud)
        try store.save("variant-fixture", account: "service-instance.v1.test")
        XCTAssertEqual(try store.read(account: "service-instance.v1.test"), "variant-fixture")
        XCTAssertEqual(try FileCredentialStore(directory: other).read(account: "service-instance.v1.test"), "")
        XCTAssertEqual(try FileCredentialStore(directory: base).read(account: "service-instance.v1.test"), "")
    }
    func testFileFormatPermissionsReplacementAndDeletion() throws {
        let directory = try temporary(), store = FileCredentialStore(directory: directory)
        let a = "service-instance.v1.instance-A", b = "service-instance.v1.instance-B"
        try store.save("one", account: a); try store.save("two", account: b)
        try store.save("new", account: a)
        XCTAssertEqual(try store.read(account: a), "new"); XCTAssertEqual(try store.read(account: b), "two")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["keys"] as? [String: String], ["instance-A": "new", "instance-B": "two"])
        XCTAssertEqual(try mode(directory), 0o700); XCTAssertEqual(try mode(store.fileURL), 0o600)
        XCTAssertEqual(try mode(directory.appendingPathComponent("credentials.lock")), 0o600)
        try store.save("", account: a)
        XCTAssertEqual(try store.read(account: a), ""); XCTAssertEqual(try store.read(account: b), "two")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".tmp") })
    }
    func testMissingDirectoryIsCreatedPrivateAndExistingFilePermissionsAreTightened() throws {
        let directory = try temporary().appendingPathComponent("new-directory")
        let store = FileCredentialStore(directory: directory)
        try store.save("fixture", account: "service-instance.v1.test")
        XCTAssertEqual(try mode(directory), 0o700)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path)
        XCTAssertEqual(try store.read(account: "service-instance.v1.test"), "fixture")
        XCTAssertEqual(try mode(store.fileURL), 0o600)
    }
    func testExistingKeysSurviveUnusedFileFields() throws {
        let file = FileCredentialStore(directory: try temporary())
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "keys": ["fixture": "existing"], "unused": []])
        try data.write(to: file.fileURL)
        XCTAssertEqual(try file.read(account: "service-instance.v1.fixture"), "existing")
        try file.save("another", account: "service-instance.v1.other")
        XCTAssertEqual(try file.read(account: "service-instance.v1.fixture"), "existing")
    }
    func testCorruptFileIsNeverOverwrittenAndErrorsDoNotContainKey() throws {
        let directory = try temporary(), file = FileCredentialStore(directory: directory)
        let corrupt = Data("{broken: PRIVATE-SENTINEL".utf8)
        try corrupt.write(to: file.fileURL)
        XCTAssertThrowsError(try file.save("another", account: "service-instance.v1.a")) {
            XCTAssertFalse($0.localizedDescription.contains("PRIVATE-SENTINEL"))
        }
        XCTAssertThrowsError(try file.read(account: "service-instance.v1.a")) {
            XCTAssertTrue($0.localizedDescription.contains(file.fileURL.path))
            guard let error = $0 as? FileCredentialError,
                  case .invalidFormat(let url) = error else {
                return XCTFail("预期凭据文件损坏错误")
            }
            XCTAssertEqual(url, file.fileURL)
            XCTAssertFalse($0.localizedDescription.contains("PRIVATE-SENTINEL"))
        }
        XCTAssertEqual(try Data(contentsOf: file.fileURL), corrupt)
    }
    func testSymlinkFileCannotRedirectCredentialWrites() throws {
        let directory = try temporary(), file = FileCredentialStore(directory: directory)
        let outside = directory.appendingPathComponent("outside.json")
        try Data("unchanged".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: file.fileURL, withDestinationURL: outside)
        XCTAssertThrowsError(try file.save("secret", account: "service-instance.v1.a"))
        XCTAssertEqual(try String(contentsOf: outside), "unchanged")
    }
    func testSeparateStoreInstancesDoNotLoseConcurrentWrites() async throws {
        let directory = try temporary()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask { try FileCredentialStore(directory: directory).save("key-\(index)", account: "service-instance.v1.\(index)") }
            }
            try await group.waitForAll()
        }
        for index in 0..<20 { XCTAssertEqual(try FileCredentialStore(directory: directory).read(account: "service-instance.v1.\(index)"), "key-\(index)") }
    }
    @MainActor func testDiagnosticsAndHistoryExportsDoNotIncludeCredentialFile() async throws {
        let directory = try temporary(), file = FileCredentialStore(directory: directory)
        try file.save("PRIVATE-EXPORT-SENTINEL", account: "service-instance.v1.fixture")
        let logger = FileDiagnosticLogger(directory: directory)
        await logger.record(.info, "app_launched", metadata: ["version": "fixture"])
        let logs = await logger.contents()
        XCTAssertFalse(logs.contains("PRIVATE-EXPORT-SENTINEL"))
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: UUID().uuidString))
        let history = HistoryStore(fileURL: directory.appendingPathComponent("history.json"), defaults: defaults)
        history.beginRecord(
            sourceText: "Hello", sourceLanguage: "en", targetLanguage: "zh-Hans",
            result: .init(providerID: .google, providerName: "Google", translatedText: "你好")
        )
        XCTAssertEqual(history.records.count, 1)
        for format in [HistoryExportFormat.json, .markdown] {
            let url = directory.appendingPathComponent("export." + format.fileExtension)
            try history.export(.history, to: url, format: format)
            let output = try String(contentsOf: url)
            XCTAssertTrue(output.contains("Hello"))
            XCTAssertFalse(output.contains("PRIVATE-EXPORT-SENTINEL"))
        }
    }
}
