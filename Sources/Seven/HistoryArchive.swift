import Foundation

/// Each collection owns its disk recovery, cached snapshot and idle lifetime.
@MainActor
final class HistoryArchive {
    private let collection: HistoryCollection
    private let originalFileURL: URL
    private var fileURL: URL
    private let logger: () -> DiagnosticLogging
    private let readData: (URL) throws -> Data
    private let idleSnapshotLifetime: Duration
    private var isBrowsing = false
    private var hasUnpersistedChanges = false
    private var idleReleaseTask: Task<Void, Never>?
    private static let idleSnapshotBudget = 8 * 1_024 * 1_024
    private(set) var cachedRecords: [TranslationRecord]?

    init(
        collection: HistoryCollection,
        fileURL: URL,
        logger: @escaping () -> DiagnosticLogging,
        readData: @escaping (URL) throws -> Data,
        idleSnapshotLifetime: Duration
    ) {
        self.collection = collection
        self.originalFileURL = fileURL
        self.fileURL = fileURL
        self.logger = logger
        self.readData = readData
        self.idleSnapshotLifetime = idleSnapshotLifetime
    }

    deinit { idleReleaseTask?.cancel() }

    var records: [TranslationRecord] {
        if let cachedRecords { return cachedRecords }
        let loaded = autoreleasepool {
            Self.load(from: fileURL, collection: collection, logger: logger, readData: readData,
                      allowsRecovery: fileURL == originalFileURL)
        }
        fileURL = loaded.url
        cachedRecords = loaded.records
        scheduleIdleRelease()
        return loaded.records
    }

    func setBrowsing(_ isBrowsing: Bool) {
        self.isBrowsing = isBrowsing
        scheduleIdleRelease()
    }

    func replace(with records: [TranslationRecord]) {
        hasUnpersistedChanges = !autoreleasepool { persist(records) }
        cachedRecords = records
        scheduleIdleRelease()
    }

    private static func fitsIdleBudget(_ records: [TranslationRecord]) -> Bool {
        var remaining = idleSnapshotBudget
        for record in records {
            // Include the per-record and per-result overhead even when the stored text is tiny.
            remaining -= 256 + record.sourceText.utf8.count
            remaining -= record.sourceLanguage.utf8.count + record.targetLanguage.utf8.count
            guard remaining >= 0 else { return false }
            for result in record.results {
                remaining -= 128 + result.translatedText.utf8.count
                remaining -= result.providerID.rawValue.utf8.count + result.providerName.utf8.count
                guard remaining >= 0 else { return false }
            }
        }
        return true
    }

    private func scheduleIdleRelease() {
        idleReleaseTask?.cancel()
        idleReleaseTask = nil
        guard !isBrowsing, !hasUnpersistedChanges, let cachedRecords,
              !Self.fitsIdleBudget(cachedRecords) else { return }
        idleReleaseTask = Task { [weak self, idleSnapshotLifetime] in
            do { try await Task.sleep(for: idleSnapshotLifetime) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.cachedRecords = nil
            self.idleReleaseTask = nil
        }
    }

    private func persist(_ records: [TranslationRecord]) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // The stored Date keeps its precision across reloads. Export uses ISO 8601.
            try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
            return true
        } catch {
            // Keep the unpersisted snapshot in memory so the next write can retry.
            return false
        }
    }

    private static func load(
        from url: URL,
        collection: HistoryCollection,
        logger: @escaping () -> DiagnosticLogging,
        readData: (URL) throws -> Data,
        allowsRecovery: Bool = true
    ) -> (records: [TranslationRecord], url: URL) {
        let manager = FileManager.default
        let recoveryURL = url.deletingLastPathComponent().appending(path: "\(collection.rawValue).recovery.json", directoryHint: .checkFileSystem)
        do {
            let data = try readData(url)
            let decoder = JSONDecoder()
            return (try decoder.decode([TranslationRecord].self, from: data), url)
        } catch {
            if (error as NSError).domain == NSCocoaErrorDomain,
               (error as NSError).code == NSFileReadNoSuchFileError {
                if allowsRecovery, manager.fileExists(atPath: recoveryURL.fileSystemPath) {
                    return load(from: recoveryURL, collection: collection, logger: logger, readData: readData, allowsRecovery: false)
                }
                return ([], url)
            }
            logFailure("\(collection.rawValue)_load_failed", error: error, logger: logger)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            + "-" + String(format: "%.9f", Date().timeIntervalSince1970)
        let backup = url.deletingLastPathComponent()
            .appending(path: "\(collection.rawValue).corrupt-\(stamp)-\(UUID().uuidString).json", directoryHint: .checkFileSystem)
        do {
            try manager.moveItem(at: url, to: backup)
            pruneCorruptBackups(beside: url, collection: collection, logger: logger)
        } catch {
            logFailure("\(collection.rawValue)_quarantine_failed", error: error, logger: logger)
            if allowsRecovery {
                return load(from: recoveryURL, collection: collection, logger: logger, readData: readData, allowsRecovery: false)
            }
            // Both files are unreadable and cannot be moved. A directory cannot be
            // atomically replaced by persist(), so neither original is overwritten.
            return ([], url.deletingLastPathComponent())
        }
        if allowsRecovery, manager.fileExists(atPath: recoveryURL.fileSystemPath) {
            return load(from: recoveryURL, collection: collection, logger: logger, readData: readData, allowsRecovery: false)
        }
        return ([], url)
    }

    private static func pruneCorruptBackups(beside url: URL, collection: HistoryCollection, logger: @escaping () -> DiagnosticLogging) {
        do {
            let backups = try FileManager.default.contentsOfDirectory(
                at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("\(collection.rawValue).corrupt-") && $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for backup in backups.dropFirst(5) {
                try FileManager.default.removeItem(at: backup)
            }
        } catch {
            logFailure("\(collection.rawValue)_backup_cleanup_failed", error: error, logger: logger)
        }
    }

    private static func logFailure(_ event: String, error: Error, logger: @escaping () -> DiagnosticLogging) {
        let metadata = ["errorType": String(describing: type(of: error))]
        Task { await logger().record(.warning, event, metadata: metadata) }
    }
}
