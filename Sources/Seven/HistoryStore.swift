import Foundation

enum HistoryExportFormat {
    case json
    case markdown

    var fileExtension: String { self == .json ? "json" : "md" }
}

@MainActor
final class HistoryStore: ObservableObject {
    private static let enabledKey = "historyEnabled"
    static let retentionKey = "historyRetention"

    @Published private(set) var revision = 0
    @Published private(set) var isBrowsing = false
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }
    @Published var retention: HistoryRetention {
        didSet {
            guard retention != oldValue else { return }
            defaults.set(retention.rawValue, forKey: Self.retentionKey)
            if retention.limit != nil { _ = trimHistoryIfNeeded(notify: true) }
        }
    }

    private let defaults: UserDefaults
    private let historyArchive: HistoryArchive
    private let favoritesArchive: HistoryArchive

    init(
        fileURL: URL? = nil,
        defaults: UserDefaults = .standard,
        logger: @autoclosure @escaping () -> DiagnosticLogging? = nil,
        idleSnapshotLifetime: Duration = .seconds(30),
        readData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0, options: .mappedIfSafe) }
    ) {
        let variant = AppDataPaths.variant(bundleIdentifier: Bundle.main.bundleIdentifier)
        let url = fileURL ?? AppDataPaths.directory(variant: variant).appending(path: "history.json")
        let resolveLogger = { logger() ?? (fileURL == nil ? FileDiagnosticLogger.shared : NoopDiagnosticLogger()) }
        self.defaults = defaults
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.retention = (defaults.object(forKey: Self.retentionKey) as? Int)
            .flatMap(HistoryRetention.init(rawValue:)) ?? .fiveHundred
        historyArchive = HistoryArchive(
            collection: .history, fileURL: url, logger: resolveLogger,
            readData: readData, idleSnapshotLifetime: idleSnapshotLifetime
        )
        favoritesArchive = HistoryArchive(
            collection: .favorites, fileURL: url.deletingLastPathComponent().appending(path: "favorites.json"),
            logger: resolveLogger, readData: readData, idleSnapshotLifetime: idleSnapshotLifetime
        )
    }

    var records: [TranslationRecord] { trimHistoryIfNeeded() }

    // A hidden view may recompute on appearance changes without loading archives.
    func browsingRecords(in collection: HistoryCollection) -> [TranslationRecord] {
        if isBrowsing { return records(in: collection) }
        return archive(for: collection).cachedRecords ?? []
    }

    func setBrowsing(_ isBrowsing: Bool) {
        guard self.isBrowsing != isBrowsing else { return }
        historyArchive.setBrowsing(isBrowsing)
        favoritesArchive.setBrowsing(isBrowsing)
        self.isBrowsing = isBrowsing
        if isBrowsing { revision &+= 1 }
    }

    func records(in collection: HistoryCollection) -> [TranslationRecord] {
        switch collection {
        case .history: records
        case .favorites: favoritesArchive.records
        }
    }

    func records(in collection: HistoryCollection, matching search: String) -> [TranslationRecord] {
        let records = records(in: collection)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? records : records.filter { $0.matches(search: query) }
    }

    /// The first successful service of a new round starts a new snapshot, reusing the
    /// newest row's identity when its source, target and mode match.
    @discardableResult
    func beginRecord(
        sourceText: String,
        sourceLanguage: String,
        targetLanguage: String,
        mode: TranslationMode,
        result: TranslationRecord.Result,
        createdAt: Date = Date()
    ) -> TranslationRecord.Reference? {
        guard isEnabled, !sourceText.isEmpty, result.hasContent else { return nil }
        var records = self.records
        let previous = records.first.flatMap { first in
            first.sourceText == sourceText && first.targetLanguage == targetLanguage && first.mode == mode ? first : nil
        }
        let record = TranslationRecord(
            id: previous?.id ?? UUID(), sourceText: sourceText, sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage, mode: mode, createdAt: createdAt, results: [result]
        )
        if previous != nil {
            records[0] = record
        } else {
            records.insert(record, at: 0)
            if let limit = retention.limit, records.count > limit {
                records.removeLast(records.count - limit)
            }
        }
        historyArchive.replace(with: records)
        notifyBrowser()
        return record.reference
    }

    /// A deleted or trimmed row is never reinserted by a late result or retry.
    func updateRecord(
        _ reference: TranslationRecord.Reference, result: TranslationRecord.Result,
        providerOrder: [TranslationProviderID]
    ) {
        guard isEnabled, result.hasContent else { return }
        var records = self.records
        let merge: (inout TranslationRecord) -> Void = { record in
            var results = record.results
            if let index = results.firstIndex(where: { $0.id == result.id }) {
                results[index] = result
            } else {
                results.append(result)
            }
            let byProvider = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
            let visible = Set(providerOrder)
            record.results = providerOrder.compactMap { byProvider[$0] } + results.filter { !visible.contains($0.id) }
        }
        var updatedHistory = false
        if let index = records.firstIndex(where: { $0.reference == reference }) {
            let previous = records[index]
            merge(&records[index])
            updatedHistory = records[index] != previous
            if updatedHistory { historyArchive.replace(with: records) }
        }
        let updatedFavorite = updateFavorite(reference, change: merge)
        if updatedHistory || updatedFavorite { notifyBrowser() }
    }

    func toggleFavorite(_ id: UUID) {
        var favorites = favoritesArchive.records
        if let index = favorites.firstIndex(where: { $0.id == id }) {
            favorites.remove(at: index)
        } else if let record = records.first(where: { $0.id == id }) {
            favorites.insert(record, at: 0)
        } else {
            return
        }
        favoritesArchive.replace(with: favorites)
        notifyBrowser()
    }

    func delete(_ id: UUID, from collection: HistoryCollection) {
        var records = records(in: collection)
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records.remove(at: index)
        archive(for: collection).replace(with: records)
        notifyBrowser()
    }

    func clear(_ collection: HistoryCollection) {
        let archive = archive(for: collection)
        // Resolve the recovery target before writing even if the browser has never opened.
        _ = archive.records
        archive.replace(with: [])
        notifyBrowser()
    }

    func export(_ collection: HistoryCollection, to url: URL, format: HistoryExportFormat) throws {
        let records = records(in: collection)
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: url, options: .atomic)
        case .markdown:
            let date = HistoryDatePresentation()
            let body = records.map { record in
                let source = LanguageCatalog.displayName(stored: record.sourceLanguage)
                let target = LanguageCatalog.displayName(stored: record.targetLanguage)
                let mode = record.mode == .translate ? "" : " · \(record.mode.title)"
                let sections = record.results.map { "### \($0.providerName)\n\n\($0.translatedText)" }
                return ([
                    "## \(date.detail(record.createdAt)) · \(source) → \(target)\(mode)",
                    "**\(L10n.text("sourceText"))**", record.sourceText
                ] + sections).joined(separator: "\n\n")
            }.joined(separator: "\n\n---\n\n")
            try Data(body.utf8).write(to: url, options: .atomic)
        }
    }

    private func trimHistoryIfNeeded(notify: Bool = false) -> [TranslationRecord] {
        let records = historyArchive.records
        guard let limit = retention.limit, records.count > limit else { return records }
        let trimmed = Array(records.prefix(limit))
        historyArchive.replace(with: trimmed)
        if notify { notifyBrowser() }
        return trimmed
    }

    private func updateFavorite(
        _ reference: TranslationRecord.Reference, change: (inout TranslationRecord) -> Void
    ) -> Bool {
        var favorites = favoritesArchive.records
        // A bookmark follows completions from its own round, even if that history row is gone.
        guard let index = favorites.firstIndex(where: { $0.reference == reference }) else { return false }
        let previous = favorites[index]
        change(&favorites[index])
        guard favorites[index] != previous else { return false }
        favoritesArchive.replace(with: favorites)
        return true
    }

    private func archive(for collection: HistoryCollection) -> HistoryArchive {
        collection == .history ? historyArchive : favoritesArchive
    }

    private func notifyBrowser() {
        if isBrowsing { revision &+= 1 }
    }
}
