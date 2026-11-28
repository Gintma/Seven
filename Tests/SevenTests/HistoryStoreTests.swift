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
            fixture.addFixture(sourceText: String(repeating: "a", count: 8 * 1_024 * 1_024), translatedText: "large",
                        sourceLanguage: "en", targetLanguage: "zh-Hans")
            var reads = 0
            let store = HistoryStore(fileURL: url, defaults: defaults, readData: { url in
                reads += 1
                return try Data(contentsOf: url, options: .mappedIfSafe)
            })
            store.setBrowsing(true)
            XCTAssertEqual(store.records.count, 1)
            XCTAssertEqual(reads, 1)
            var refreshes = 0
            // Simulates a closed yet retained hosting view consuming revision and reading records from multiple points in a single layout pass.
            let observer = store.$revision.dropFirst().sink { [weak store] _ in
                refreshes += 1
                _ = store?.records
                _ = store?.records
                _ = store?.records
            }
            defer { observer.cancel() }
            store.setBrowsing(false)
            for source in ["first", "second"] {
                store.addFixture(sourceText: source, translatedText: "result",
                          sourceLanguage: "en", targetLanguage: "zh-Hans")
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
        store.addFixture(sourceText: String(repeating: "a", count: 8 * 1_024 * 1_024), translatedText: "one",
                  sourceLanguage: "en", targetLanguage: "zh-Hans")
        XCTAssertEqual(store.browsingRecords(in: .history).count, 1)
        XCTAssertTrue(try Data(contentsOf: url).count > 8 * 1_024 * 1_024)
        store.setBrowsing(false)
        XCTAssertEqual(store.browsingRecords(in: .history).count, 1, "关闭后的短时间内应保留快照")
        let readsBeforeIdle = reads
        for _ in 0..<100 where !store.browsingRecords(in: .history).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(store.browsingRecords(in: .history).isEmpty, "空闲时应释放超预算快照")
        XCTAssertEqual(reads, readsBeforeIdle, "隐藏视图的读访问不应重载文件")
        for source in ["first", "second"] {
            store.addFixture(sourceText: source, translatedText: "result",
                      sourceLanguage: "en", targetLanguage: "zh-Hans")
        }
        XCTAssertEqual(reads, readsBeforeIdle + 1, "过期后只应解码一次，连续写入继续复用")
        store.setBrowsing(true)
        XCTAssertEqual(store.browsingRecords(in: .history).prefix(2).map(\.sourceText), ["second", "first"])
        XCTAssertEqual(store.browsingRecords(in: .history).count, 3)
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

        store.addFixture(
            sourceText: "Hello", translatedText: "你好",
            sourceLanguage: "en", targetLanguage: "zh-Hans"
        )
        store.addFixture(
            sourceText: "Hello", translatedText: "你好",
            sourceLanguage: "en", targetLanguage: "zh-Hans"
        )

        XCTAssertEqual(store.records.count, 1)
        let reference = try XCTUnwrap(store.records.first?.reference)
        store.toggleFavorite(reference)
        XCTAssertEqual(store.records(in: .favorites).first?.reference, reference)

        let reloaded = HistoryStore(fileURL: fileURL, defaults: defaults)
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.records(in: .favorites).first?.reference, reference)
    }

    func testDeletedAndClearedHistoryLeavesFavoritesAndFavoriteDeletionLeavesHistory() throws {
        try withHistoryDirectory { directory, defaults in
            let url = directory.appendingPathComponent("history.json")
            let store = HistoryStore(fileURL: url, defaults: defaults)
            let first = try XCTUnwrap(store.addFixture(sourceText: "First", translatedText: "第一"))
            let second = try XCTUnwrap(store.addFixture(sourceText: "Second", translatedText: "第二"))
            store.toggleFavorite(first)
            store.toggleFavorite(second)

            store.delete(first, from: .history)
            XCTAssertEqual(store.records.map(\.reference), [second])
            XCTAssertEqual(store.records(in: .favorites).map(\.reference), [second, first])
            store.delete(second, from: .favorites)
            XCTAssertEqual(store.records.map(\.reference), [second])
            XCTAssertEqual(store.records(in: .favorites).map(\.reference), [first])
            store.toggleFavorite(second)
            store.toggleFavorite(second)
            XCTAssertEqual(store.records.map(\.reference), [second])

            store.clear(.history)
            let current = HistoryStore(fileURL: url, defaults: defaults)
            XCTAssertTrue(current.records.isEmpty)
            XCTAssertEqual(current.records(in: .favorites).map(\.reference), [first])
            current.toggleFavorite(first)
            XCTAssertTrue(current.records(in: .favorites).isEmpty)
        }
    }

    func testClearingFavoritesPreservesHistoryAndLateResultsDoNotRestoreFavorites() throws {
        try withHistoryDirectory { directory, defaults in
            let url = directory.appendingPathComponent("history.json")
            let store = HistoryStore(fileURL: url, defaults: defaults)
            let favoriteOnly = try XCTUnwrap(store.addFixture(sourceText: "Favorite only", translatedText: "只有收藏"))
            store.toggleFavorite(favoriteOnly)
            store.delete(favoriteOnly, from: .history)
            let shared = try XCTUnwrap(store.addFixture(sourceText: "History record", translatedText: "历史记录"))
            store.toggleFavorite(shared)
            XCTAssertEqual(store.records(in: .favorites).map(\.id), [shared.id, favoriteOnly.id])
            let historyFile = try Data(contentsOf: url)

            store.clear(.favorites)

            XCTAssertTrue(store.records(in: .favorites).isEmpty)
            XCTAssertEqual(store.records.map(\.id), [shared.id])
            XCTAssertEqual(try Data(contentsOf: url), historyFile)

            let result = TranslationRecord.Result(providerID: .youdao, providerName: "Youdao", translatedText: "另一份结果")
            store.updateRecord(shared, result: result, providerOrder: [.google, .youdao])
            store.updateRecord(favoriteOnly, result: result, providerOrder: [.google, .youdao])

            let reloaded = HistoryStore(fileURL: url, defaults: defaults)
            XCTAssertEqual(reloaded.records.map(\.id), [shared.id])
            XCTAssertEqual(reloaded.records.first?.results.map(\.providerID), [.google, .youdao])
            XCTAssertTrue(reloaded.records(in: .favorites).isEmpty)
        }
    }

    func testRetentionTrimsImmediatelyAndUnlimitedSurvivesReload() throws {
        try withHistoryDirectory { directory, defaults in
            let url = directory.appendingPathComponent("history.json")
            let store = HistoryStore(fileURL: url, defaults: defaults)
            XCTAssertEqual(store.retention, .fiveHundred)
            store.retention = .unlimited
            let fixture = (0..<1005).reversed().map { index in
                TranslationRecord(
                    id: UUID(), sourceText: "Source \(index)", sourceLanguage: "en", targetLanguage: "zh-Hans",
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    results: [.init(providerID: .google, providerName: "Google", translatedText: "译文")]
                )
            }
            try JSONEncoder().encode(fixture).write(to: url)
            let reloaded = HistoryStore(fileURL: url, defaults: defaults)
            XCTAssertEqual(reloaded.retention, .unlimited)
            XCTAssertEqual(reloaded.records.count, 1005)
            let newest = try XCTUnwrap(reloaded.addFixture(sourceText: "Newest", translatedText: "最新")).id
            for record in fixture.suffix(101) { reloaded.toggleFavorite(record.reference) }
            XCTAssertEqual(reloaded.records.count, 1006)
            let favorites = reloaded.records(in: .favorites)
            reloaded.retention = .oneHundred
            XCTAssertEqual(reloaded.records.map(\.id), [newest] + fixture.prefix(99).map(\.id))
            XCTAssertEqual(reloaded.records(in: .favorites), favorites)
            XCTAssertEqual(favorites.count, 101)
            let trimmed = HistoryStore(fileURL: url, defaults: defaults)
            XCTAssertEqual(trimmed.retention, .oneHundred)
            XCTAssertEqual(trimmed.records, reloaded.records)
            XCTAssertEqual(trimmed.records(in: .favorites), favorites)
        }
    }

    func testAdjacentRetranslationCanBeFavoritedIndependentlyOfPreviousRound() throws {
        try withHistoryDirectory { directory, defaults in
            let url = directory.appendingPathComponent("history.json")
            let store = HistoryStore(fileURL: url, defaults: defaults)
            let firstTime = Date(timeIntervalSince1970: 100)
            let first = try XCTUnwrap(store.addFixture(sourceText: "Hello", translatedText: "第一版", createdAt: firstTime))
            store.toggleFavorite(first)
            let second = try XCTUnwrap(store.addFixture(
                sourceText: "Hello", translatedText: "第二版", createdAt: firstTime.addingTimeInterval(1)
            ))

            XCTAssertEqual(store.records.map(\.reference), [second])
            XCTAssertNotEqual(first.id, second.id)
            XCTAssertFalse(store.records(in: .favorites).contains { $0.id == second.id })
            store.toggleFavorite(second)
            XCTAssertEqual(store.records(in: .favorites).map(\.reference), [second, first])
            XCTAssertEqual(store.records(in: .favorites).compactMap { $0.results.first?.translatedText }, ["第二版", "第一版"])

            store.toggleFavorite(second)
            let reloaded = HistoryStore(fileURL: url, defaults: defaults)
            XCTAssertEqual(reloaded.records(in: .favorites).map(\.reference), [first])
            XCTAssertEqual(reloaded.records.map(\.reference), [second])
        }
    }

    func testTrialSnapshotsWithReusedUUIDStillHaveIndependentFavoriteAndDeleteActions() throws {
        try withHistoryDirectory { directory, defaults in
            let id = UUID()
            func snapshot(_ text: String, at time: TimeInterval) -> TranslationRecord {
                TranslationRecord(
                    id: id, sourceText: "Hello", sourceLanguage: "en", targetLanguage: "zh-Hans",
                    createdAt: Date(timeIntervalSince1970: time),
                    results: [.init(providerID: .google, providerName: "Google", translatedText: text)]
                )
            }
            let favorite = snapshot("第一版", at: 100)
            let history = snapshot("第二版", at: 101)
            let url = directory.appendingPathComponent("history.json")
            let encoder = JSONEncoder()
            try encoder.encode([history]).write(to: url)
            try encoder.encode([favorite]).write(to: directory.appendingPathComponent("favorites.json"))

            let store = HistoryStore(fileURL: url, defaults: defaults)
            store.toggleFavorite(history.reference)
            XCTAssertEqual(store.records(in: .favorites), [history, favorite])
            store.delete(favorite.reference, from: .favorites)
            XCTAssertEqual(store.records(in: .favorites), [history])
            XCTAssertEqual(store.records, [history])
        }
    }

    func testUpdateRecordRepairsDuplicateProvidersFromDiskAndKeepsLatestResult() throws {
        try withHistoryDirectory { directory, defaults in
            let url = directory.appendingPathComponent("history.json")
            let favoritesURL = directory.appendingPathComponent("favorites.json")
            let duplicated = TranslationRecord(
                id: UUID(), sourceText: "Hello", sourceLanguage: "en", targetLanguage: "zh-Hans",
                createdAt: Date(timeIntervalSince1970: 100),
                results: [
                    .init(providerID: .google, providerName: "Google", translatedText: "旧结果"),
                    .init(providerID: .youdao, providerName: "Youdao", translatedText: "旧有道结果"),
                    .init(providerID: .google, providerName: "Google", translatedText: "稍新结果"),
                    .init(providerID: .youdao, providerName: "Youdao", translatedText: "保留的有道结果")
                ]
            )
            let data = try JSONEncoder().encode([duplicated])
            try data.write(to: url)
            try data.write(to: favoritesURL)
            let store = HistoryStore(fileURL: url, defaults: defaults)

            let fresh = TranslationRecord.Result(providerID: .google, providerName: "Google", translatedText: "重试结果")
            store.updateRecord(duplicated.reference, result: fresh, providerOrder: [.google])

            let reloaded = HistoryStore(fileURL: url, defaults: defaults)
            for collection in HistoryCollection.allCases {
                let record = try XCTUnwrap(reloaded.records(in: collection).first)
                XCTAssertEqual(record.reference, duplicated.reference)
                XCTAssertEqual(record.results.map(\.providerID), [.google, .youdao])
                XCTAssertEqual(record.results.map(\.translatedText), ["重试结果", "保留的有道结果"])
            }
        }
    }

    func testAdjacentRoundReplacesResultsAndLateUpdateDoesNotRecreateDeletedHistory() throws {
        try withHistoryDirectory { directory, defaults in
            let url = directory.appendingPathComponent("history.json")
            let store = HistoryStore(fileURL: url, defaults: defaults)
            let start = Date(timeIntervalSince1970: 10.123)
            let providerOrder: [TranslationProviderID] = [.youdao, .google]
            let original = try XCTUnwrap(store.addFixture(sourceText: "Hello", translatedText: "第一版", createdAt: start))
            store.toggleFavorite(original)
            let favorites = store.records(in: .favorites)
            let next = start.addingTimeInterval(20)
            let repeated = try XCTUnwrap(store.addFixture(
                sourceText: "Hello", translatedText: "新版", sourceLanguage: "en-US", createdAt: next
            ))
            XCTAssertNotEqual(original.id, repeated.id)
            XCTAssertEqual(store.records.map(\.createdAt), [next])
            XCTAssertEqual(store.records(in: .favorites), favorites)

            let other = TranslationRecord.Result(providerID: .youdao, providerName: "Youdao", translatedText: "另一版")
            store.updateRecord(repeated, result: other, providerOrder: providerOrder)
            XCTAssertEqual(store.records.first?.results.map(\.providerID), providerOrder)
            XCTAssertEqual(store.records.first?.createdAt, next)
            XCTAssertEqual(store.records(in: .favorites), favorites)
            store.clear(.history)
            store.updateRecord(original, result: other, providerOrder: providerOrder)
            XCTAssertTrue(store.records.isEmpty)
            XCTAssertEqual(store.records(in: .favorites).first?.results.map(\.providerID), providerOrder)

            store.addFixture(sourceText: "Hello", translatedText: "简体")
            store.addFixture(sourceText: "Hello", translatedText: "繁體", targetLanguage: "zh-Hant")
            store.addFixture(sourceText: "Other", translatedText: "另一句", targetLanguage: "zh-Hant")
            store.addFixture(sourceText: "Hello", translatedText: "改寫", targetLanguage: "zh-Hant")
            XCTAssertEqual(store.records.map(\.sourceText), ["Hello", "Other", "Hello", "Hello"])
            XCTAssertEqual(store.records.map(\.targetLanguage), ["zh-Hant", "zh-Hant", "zh-Hant", "zh-Hans"])
        }
    }

    func testSearchMatchesEveryTranslationAndExportIncludesEveryServiceInSelectedCollection() throws {
        try withHistoryDirectory { directory, defaults in
            let url = directory.appendingPathComponent("history.json")
            let store = HistoryStore(fileURL: url, defaults: defaults)
            let record = try XCTUnwrap(store.addFixture(sourceText: "Favorite source", translatedText: "First answer"))
            let id = record.id
            store.toggleFavorite(record)
            store.updateRecord(record, result: .init(providerID: .youdao, providerName: "Youdao", translatedText: "Unique answer"),
                               providerOrder: [.youdao, .google])
            store.delete(record, from: .history)
            let newID = try XCTUnwrap(store.addFixture(sourceText: "History source", translatedText: "Other answer")).id

            XCTAssertEqual(store.records(in: .favorites, matching: "  UNIQUE  ").map(\.id), [id])
            XCTAssertEqual(store.records(in: .favorites, matching: "FIRST").map(\.id), [id])
            XCTAssertEqual(store.records(in: .history, matching: "history SOURCE").map(\.id), [newID])
            XCTAssertTrue(store.records(in: .history, matching: "unique").isEmpty)

            for collection in HistoryCollection.allCases {
                let jsonURL = directory.appendingPathComponent(collection.rawValue + "-export.json")
                let markdownURL = directory.appendingPathComponent(collection.rawValue + "-export.md")
                try store.export(collection, to: jsonURL, format: .json)
                try store.export(collection, to: markdownURL, format: .markdown)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let exported = try decoder.decode([TranslationRecord].self, from: Data(contentsOf: jsonURL))
                let markdown = try String(contentsOf: markdownURL)
                if collection == .favorites {
                    XCTAssertEqual(exported.map(\.id), [id])
                    XCTAssertEqual(exported.first?.results.map(\.providerName), ["Youdao", "Google"])
                    XCTAssertEqual(exported.first?.results.map(\.translatedText), ["Unique answer", "First answer"])
                    XCTAssertTrue(markdown.contains("### Youdao\n\nUnique answer"))
                    XCTAssertTrue(markdown.contains("### Google\n\nFirst answer"))
                    XCTAssertFalse(markdown.contains("History source"))
                } else {
                    XCTAssertEqual(exported.map(\.id), [newID])
                    XCTAssertTrue(markdown.contains("### Google\n\nOther answer"))
                    XCTAssertFalse(markdown.contains("Favorite source"))
                }
            }
        }
    }

    func testPreviousRecordsWithModeAreReadableAndSaveAndExportWithoutIt() throws {
        try withHistoryDirectory { directory, defaults in
            let historyURL = directory.appendingPathComponent("history.json")
            let favoritesURL = directory.appendingPathComponent("favorites.json")
            let store = HistoryStore(fileURL: historyURL, defaults: defaults)
            let date = Date(timeIntervalSince1970: 123)
            let reference = try XCTUnwrap(store.addFixture(sourceText: "Hello", translatedText: "你好", createdAt: date))
            store.toggleFavorite(reference)

            func entries(at url: URL) throws -> [[String: Any]] {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
            }
            for url in [historyURL, favoritesURL] {
                var saved = try XCTUnwrap(entries(at: url).first)
                saved["mode"] = "custom"
                try JSONSerialization.data(withJSONObject: [saved]).write(to: url)
            }

            let reloaded = HistoryStore(fileURL: historyURL, defaults: defaults)
            let dateLabel = HistoryDatePresentation().detail(date)
            let source = LanguageCatalog.displayName(stored: "en")
            let target = LanguageCatalog.displayName(stored: "zh-Hans")
            for collection in HistoryCollection.allCases {
                let record = try XCTUnwrap(reloaded.records(in: collection).first)
                XCTAssertEqual(record.reference, reference)
                XCTAssertEqual(record.results.map(\.translatedText), ["你好"])

                let jsonURL = directory.appendingPathComponent("export-" + collection.rawValue + ".json")
                let markdownURL = directory.appendingPathComponent("export-" + collection.rawValue + ".md")
                try reloaded.export(collection, to: jsonURL, format: .json)
                try reloaded.export(collection, to: markdownURL, format: .markdown)
                XCTAssertNil(try XCTUnwrap(entries(at: jsonURL).first)["mode"])
                XCTAssertEqual(try String(contentsOf: markdownURL).components(separatedBy: "\n").first,
                               "## \(dateLabel) · \(source) → \(target)")
            }

            reloaded.updateRecord(
                reference, result: .init(providerID: .youdao, providerName: "Youdao", translatedText: "另一个译文"),
                providerOrder: [.google, .youdao]
            )
            for url in [historyURL, favoritesURL] {
                XCTAssertNil(try XCTUnwrap(entries(at: url).first)["mode"])
            }
        }
    }

    func testIdleFavoritesReleaseCountsPerRecordOverheadAndDoesNotReloadHiddenViews() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(isolatedDefaults())
        let fixtures = (0..<22_000).map { index in
            TranslationRecord(
                id: UUID(), sourceText: "a", sourceLanguage: "en", targetLanguage: "es",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                results: [.init(providerID: .google, providerName: "Google", translatedText: "b")]
            )
        }
        let favoritesURL = directory.appendingPathComponent("favorites.json")
        try JSONEncoder().encode(fixtures).write(to: favoritesURL)
        var reads: [URL] = []
        let store = HistoryStore(
            fileURL: directory.appendingPathComponent("history.json"), defaults: defaults,
            idleSnapshotLifetime: .milliseconds(20), readData: { url in
                reads.append(url)
                return try Data(contentsOf: url)
            }
        )
        store.setBrowsing(true)
        XCTAssertEqual(store.browsingRecords(in: .favorites).count, 22_000)
        store.setBrowsing(false)
        for _ in 0..<100 where !store.browsingRecords(in: .favorites).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(store.browsingRecords(in: .favorites).isEmpty)
        XCTAssertEqual(reads.map(\.lastPathComponent), ["favorites.json"])
        store.setBrowsing(true)
        XCTAssertEqual(store.browsingRecords(in: .favorites).count, 22_000)
        XCTAssertEqual(reads.map(\.lastPathComponent), ["favorites.json", "favorites.json"])
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
        store.addFixture(
            sourceText: "Ignored", translatedText: "忽略",
            sourceLanguage: "en", targetLanguage: "zh-Hans"
        )
        XCTAssertTrue(store.records.isEmpty)

        store.isEnabled = true
        store.addFixture(
            sourceText: "Hello", translatedText: "你好",
            sourceLanguage: "en", targetLanguage: "zh-Hans"
        )
        let markdownURL = directory.appendingPathComponent("export.md")
        let jsonURL = directory.appendingPathComponent("export.json")
        try store.export(.history, to: markdownURL, format: .markdown)
        try store.export(.history, to: jsonURL, format: .json)

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
        store.addFixture(sourceText: "New", translatedText: "新", sourceLanguage: "en", targetLanguage: "zh-Hans")
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
        store.addFixture(sourceText: "PRIVATE SOURCE", translatedText: "PRIVATE TRANSLATION", sourceLanguage: "en", targetLanguage: "zh-Hans")
        let view = HistoryView(store: store, speech: SpeechController(settings: SettingsStore(defaults: defaults)))
        for format in [HistoryExportFormat.json, .markdown] {
            var alert: NSAlert?
            view.export(.history, to: directory.appendingPathComponent("missing/export"), format: format) { alert = $0 }
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
            store.addFixture(sourceText: "New", translatedText: "新", sourceLanguage: "en", targetLanguage: "zh-Hans")
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
            store.addFixture(sourceText: "Recovered", translatedText: "恢复", sourceLanguage: "en", targetLanguage: "zh-Hans")
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
            store.addFixture(sourceText: "New", translatedText: "新", sourceLanguage: "en", targetLanguage: "zh-Hans")
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
    func testHistoryWindowRetainsItsResizedFrameAcrossCloseAndReopen() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try XCTUnwrap(isolatedDefaults())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(fileURL: directory.appendingPathComponent("history.json"), defaults: defaults)
        store.addFixture(
            sourceText: String(repeating: "Long source line. ", count: 40),
            translatedText: String(repeating: "Long translation line. ", count: 40)
        )
        let frameName = UUID().uuidString
        let controller = HistoryWindowController(
            store: store, speech: SpeechController(settings: SettingsStore(defaults: defaults)), frameName: frameName
        )
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        defer {
            controller.close()
            NSWindow.removeFrame(usingName: frameName)
        }
        try await Task.sleep(for: .milliseconds(50))
        let original = window.frame.size
        window.setContentSize(NSSize(width: original.width + 70, height: original.height + 60))
        try await Task.sleep(for: .milliseconds(50))
        let resized = window.frame.size
        XCTAssertGreaterThan(resized.width, original.width)
        XCTAssertGreaterThan(resized.height, original.height)

        controller.close()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(window.frame.size, resized)
        controller.showWindow(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(window.frame.size, resized)
    }

    func testHistoryWindowRejectsWidthAndHeightBelowMinimumDuringResize() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try XCTUnwrap(isolatedDefaults())
        let frameName = UUID().uuidString
        let store = HistoryStore(fileURL: directory.appendingPathComponent("history.json"), defaults: defaults)
        store.addFixture(sourceText: "The library opens at nine.", translatedText: "图书馆九点开门。")
        let controller = HistoryWindowController(
            store: store, speech: SpeechController(settings: SettingsStore(defaults: defaults)), frameName: frameName
        )
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        defer {
            controller.close()
            NSWindow.removeFrame(usingName: frameName)
            try? FileManager.default.removeItem(at: directory)
        }
        try await Task.sleep(for: .milliseconds(50))

        let minimum = Design.History.minimumSize
        for proposed in [
            NSSize(width: minimum.width - 80, height: minimum.height + 60),
            NSSize(width: minimum.width + 80, height: minimum.height - 60)
        ] {
            let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: proposed))
            let resized = window.delegate?.windowWillResize?(window, to: frame.size) ?? frame.size
            let accepted = window.contentRect(forFrameRect: NSRect(origin: .zero, size: resized)).size
            XCTAssertEqual(accepted.width, max(proposed.width, minimum.width))
            XCTAssertEqual(accepted.height, max(proposed.height, minimum.height))

            window.setContentSize(proposed)
            window.layoutIfNeeded()
            let actual = window.contentRect(forFrameRect: window.frame).size
            XCTAssertEqual(actual.width, max(proposed.width, minimum.width))
            XCTAssertEqual(actual.height, max(proposed.height, minimum.height))
        }
    }

    func testHistoryWindowRecoversFromPersistedUndersizedFrame() throws {
        _ = NSApplication.shared
        try withHistoryDirectory { directory, defaults in
            let frameName = UUID().uuidString
            defer { NSWindow.removeFrame(usingName: frameName) }
            let savedWindow = NSWindow(
                contentRect: NSRect(x: 20, y: 20, width: 421, height: 161),
                styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false
            )
            savedWindow.saveFrame(usingName: frameName)
            let store = HistoryStore(fileURL: directory.appendingPathComponent("history.json"), defaults: defaults)
            let controller = HistoryWindowController(
                store: store, speech: SpeechController(settings: SettingsStore(defaults: defaults)), frameName: frameName
            )
            controller.showWindow(nil)
            defer { controller.close() }
            let window = try XCTUnwrap(controller.window)
            let size = window.contentRect(forFrameRect: window.frame).size
            XCTAssertGreaterThanOrEqual(size.width, Design.History.minimumSize.width)
            XCTAssertGreaterThanOrEqual(size.height, Design.History.minimumSize.height)
        }
    }

    func testHistoryWindowCloseStopsOnlyHistoryPlayback() throws {
        _ = NSApplication.shared
        try withHistoryDirectory { directory, defaults in
            let store = HistoryStore(fileURL: directory.appendingPathComponent("history.json"), defaults: defaults)
            let backend = HistorySpeechBackend()
            let speech = SpeechController(
                settings: SettingsStore(defaults: defaults), systemBackend: backend, systemVoiceLanguages: { ["en-US"] }
            )
            speech.selectEngine(.system)
            let window = HistoryWindowController(store: store, speech: speech)
            window.showWindow(nil)
            let historyContent = SpeechContent.history(recordID: UUID(), provider: nil)
            speech.toggle(content: historyContent, text: "History sample", declaredLanguage: "en")
            XCTAssertTrue(speech.isActive(historyContent))
            window.close()
            XCTAssertEqual(speech.state, .idle)
            XCTAssertFalse(store.isBrowsing)

            window.showWindow(nil)
            speech.toggle(content: .source, text: "Panel sample", declaredLanguage: "en")
            XCTAssertTrue(speech.isActive(.source))
            window.close()
            XCTAssertTrue(speech.isActive(.source))
            speech.stop()
            XCTAssertEqual(backend.spoken, ["History sample", "Panel sample"])
        }
    }

    func testHistoryWindowLoadsCurrentRecordsLazilyAndReusesItsContent() throws {
        _ = NSApplication.shared
        try withHistoryDirectory { directory, defaults in
            let store = HistoryStore(fileURL: directory.appendingPathComponent("history.json"), defaults: defaults)
            let controller = HistoryWindowController(store: store, speech: SpeechController(settings: SettingsStore(defaults: defaults)))
            XCTAssertFalse(controller.isWindowLoaded)
            store.addFixture(sourceText: "输入", translatedText: "Result", sourceLanguage: "zh-Hans", targetLanguage: "en")
            controller.showWindow(nil)
            let window = try XCTUnwrap(controller.window)
            defer { controller.close() }
            let host = try XCTUnwrap(window.contentView as? NSHostingView<HistoryView>)
            XCTAssertTrue(host.rootView.store === store)
            XCTAssertEqual(host.rootView.store.records.flatMap(\.results).map(\.translatedText), ["Result"])
            controller.close()
            controller.showWindow(nil)
            XCTAssertTrue(controller.window === window)
            XCTAssertTrue(window.contentView === host)
        }
    }
}

@MainActor
extension HistoryStore {
    @discardableResult
    fileprivate func addFixture(
        sourceText: String, translatedText: String, sourceLanguage: String = "en",
        targetLanguage: String = "zh-Hans", createdAt: Date = Date()
    ) -> TranslationRecord.Reference? {
        beginRecord(sourceText: sourceText, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                    result: .init(providerID: .google, providerName: "Google", translatedText: translatedText),
                    createdAt: createdAt)
    }
}

@MainActor
private final class HistorySpeechBackend: SystemSpeechBackend {
    var onEnd: ((SpeechPlaybackEnd) -> Void)?
    private(set) var spoken: [String] = []

    func speak(_ text: String, languageIdentifier: String?, rate: SpeechRate) { spoken.append(text) }
    func pause() -> Bool { true }
    func resume() -> Bool { true }
    func stop() {}
}
