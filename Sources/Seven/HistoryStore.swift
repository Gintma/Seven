import Foundation

struct TranslationRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var sourceText: String
    var translatedText: String
    var sourceLanguage: String
    var targetLanguage: String
    var mode: TranslationMode
    var createdAt: Date
    var isFavorite: Bool
}

enum HistoryExportFormat {
    case json
    case markdown

    var fileExtension: String { self == .json ? "json" : "md" }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var revision = 0
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: enabledKey) }
    }

    private let originalFileURL: URL
    private var fileURL: URL
    private let defaults: UserDefaults
    private let enabledKey = "historyEnabled"
    private let maximumRecords: Int
    private let logger: () -> DiagnosticLogging
    private let readData: (URL) throws -> Data
    private let idleSnapshotLifetime: Duration
    private var cachedRecords: [TranslationRecord]?
    private(set) var isBrowsing = false
    private var hasUnpersistedChanges = false
    private var idleReleaseTask: Task<Void, Never>?
    private static let idleBodyBudget = 8 * 1_024 * 1_024

    init(
        fileURL: URL? = nil,
        defaults: UserDefaults = .standard,
        maximumRecords: Int = 500,
        logger: @autoclosure @escaping () -> DiagnosticLogging? = nil,
        idleSnapshotLifetime: Duration = .seconds(30),
        readData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0, options: .mappedIfSafe) }
    ) {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appending(path: "Seven", directoryHint: .isDirectory)
        let url = fileURL ?? directory.appending(path: "history.json", directoryHint: .checkFileSystem)
        // Resolve even the default shared logger only when an event is recorded.
        // Explicit file URLs keep isolated stores away from user diagnostic files.
        self.logger = { logger() ?? (fileURL == nil ? FileDiagnosticLogger.shared : NoopDiagnosticLogger()) }
        self.readData = readData
        self.idleSnapshotLifetime = idleSnapshotLifetime
        self.originalFileURL = url
        self.fileURL = url
        self.defaults = defaults
        self.maximumRecords = maximumRecords
        self.isEnabled = defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    deinit { idleReleaseTask?.cancel() }

    var records: [TranslationRecord] {
        if let cachedRecords { return cachedRecords }
        let loaded = autoreleasepool {
            Self.load(from: fileURL, logger: logger, readData: readData, allowsRecovery: fileURL == originalFileURL)
        }
        fileURL = loaded.url
        cachedRecords = loaded.records
        scheduleIdleRelease()
        return loaded.records
    }

    // 不可见的托管视图仍可因系统外观等原因重算，但只能读已有快照。
    var browsingRecords: [TranslationRecord] { isBrowsing ? records : cachedRecords ?? [] }

    func setBrowsing(_ isBrowsing: Bool) {
        guard self.isBrowsing != isBrowsing else { return }
        self.isBrowsing = isBrowsing
        scheduleIdleRelease()
        if isBrowsing { revision &+= 1 }
    }

    func add(
        sourceText: String,
        translatedText: String,
        sourceLanguage: String,
        targetLanguage: String,
        mode: TranslationMode
    ) {
        guard isEnabled, !sourceText.isEmpty, !translatedText.isEmpty else { return }
        var records = self.records
        if let first = records.first,
           first.sourceText == sourceText,
           first.translatedText == translatedText,
           first.targetLanguage == targetLanguage,
           first.mode == mode {
            records[0].createdAt = Date()
        } else {
            records.insert(TranslationRecord(
                id: UUID(),
                sourceText: sourceText,
                translatedText: translatedText,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                mode: mode,
                createdAt: Date(),
                isFavorite: false
            ), at: 0)
        }
        if records.count > maximumRecords {
            let favorites = records.filter(\.isFavorite)
            let regular = records.filter { !$0.isFavorite }.prefix(maximumRecords - min(favorites.count, maximumRecords))
            records = Array((favorites + regular).prefix(maximumRecords)).sorted { $0.createdAt > $1.createdAt }
        }
        update(records)
    }

    func toggleFavorite(_ id: UUID) {
        var records = self.records
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].isFavorite.toggle()
        update(records)
    }

    func delete(_ id: UUID) {
        var records = self.records
        records.removeAll { $0.id == id }
        update(records)
    }

    func clear() {
        // Resolve the recovery target before writing even if the browser has never opened.
        _ = records
        update([])
    }

    func export(_ records: [TranslationRecord], to url: URL, format: HistoryExportFormat) throws {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: url, options: .atomic)
        case .markdown:
            let formatter = DateFormatter()
            formatter.locale = L10n.locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let body = records.map { record in
                """
                ## \(formatter.string(from: record.createdAt)) · \(LanguageCatalog.displayName(stored: record.targetLanguage))

                **\(L10n.text("sourceText"))**

                \(record.sourceText)

                **\(L10n.text("translation"))**

                \(record.translatedText)
                """
            }.joined(separator: "\n\n---\n\n")
            try Data(body.utf8).write(to: url, options: .atomic)
        }
    }

    private static func fitsIdleBudget(_ records: [TranslationRecord]) -> Bool {
        var remaining = idleBodyBudget
        for record in records {
            remaining -= record.sourceText.utf8.count
            guard remaining >= 0 else { return false }
            remaining -= record.translatedText.utf8.count
            guard remaining >= 0 else { return false }
        }
        return true
    }

    private func update(_ records: [TranslationRecord]) {
        hasUnpersistedChanges = !autoreleasepool { persist(records) }
        cachedRecords = records
        scheduleIdleRelease()
        if isBrowsing { revision &+= 1 }
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
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: fileURL, options: .atomic)
            return true
        } catch {
            // History persistence must not interrupt translation.
            return false
        }
    }

    private static func load(
        from url: URL,
        logger: @escaping () -> DiagnosticLogging,
        readData: (URL) throws -> Data,
        allowsRecovery: Bool = true
    ) -> (records: [TranslationRecord], url: URL) {
        let manager = FileManager.default
        let recoveryURL = url.deletingLastPathComponent().appending(path: "history.recovery.json", directoryHint: .checkFileSystem)
        do {
            let data = try readData(url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try decoder.decode([TranslationRecord].self, from: data), url)
        } catch {
            if (error as NSError).domain == NSCocoaErrorDomain,
               (error as NSError).code == NSFileReadNoSuchFileError {
                if allowsRecovery, manager.fileExists(atPath: recoveryURL.fileSystemPath) {
                    return load(from: recoveryURL, logger: logger, readData: readData, allowsRecovery: false)
                }
                return ([], url)
            }
            logFailure("history_load_failed", error: error, logger: logger)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            + "-" + String(format: "%.9f", Date().timeIntervalSince1970)
        let backup = url.deletingLastPathComponent()
            .appending(path: "history.corrupt-\(stamp)-\(UUID().uuidString).json", directoryHint: .checkFileSystem)
        do {
            try manager.moveItem(at: url, to: backup)
            pruneCorruptBackups(beside: url, logger: logger)
        } catch {
            logFailure("history_quarantine_failed", error: error, logger: logger)
            if allowsRecovery {
                return load(from: recoveryURL, logger: logger, readData: readData, allowsRecovery: false)
            }
            // Both files are unreadable and cannot be moved. A directory cannot be
            // atomically replaced by persist(), so neither original is overwritten.
            return ([], url.deletingLastPathComponent())
        }
        if allowsRecovery, manager.fileExists(atPath: recoveryURL.fileSystemPath) {
            return load(from: recoveryURL, logger: logger, readData: readData, allowsRecovery: false)
        }
        return ([], url)
    }

    private static func pruneCorruptBackups(beside url: URL, logger: @escaping () -> DiagnosticLogging) {
        do {
            let backups = try FileManager.default.contentsOfDirectory(
                at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("history.corrupt-") && $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for backup in backups.dropFirst(5) {
                try FileManager.default.removeItem(at: backup)
            }
        } catch {
            logFailure("history_backup_cleanup_failed", error: error, logger: logger)
        }
    }

    private static func logFailure(_ event: String, error: Error, logger: @escaping () -> DiagnosticLogging) {
        let metadata = ["errorType": String(describing: type(of: error))]
        Task { await logger().record(.warning, event, metadata: metadata) }
    }
}
