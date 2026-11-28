import CryptoKit
import Foundation
import SQLite3

struct TranslationProviderID: RawRepresentable, Hashable, Codable, Identifiable, Sendable, CaseIterable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let ecdict = Self(rawValue: "ecdict")
    static let appleTranslation = Self(rawValue: "appleTranslation")
    static let youdao = Self(rawValue: "youdao")
    static let google = Self(rawValue: "google")
    /// Preserves a stable identity for migrated legacy custom services; new services get their own UUID.
    static let compatible = Self(rawValue: "compatible")
    static let allCases: [Self] = [.ecdict, .appleTranslation, .youdao, .google, .compatible]
    var id: String { rawValue }
    var isBuiltIn: Bool { [Self.ecdict, .appleTranslation, .youdao, .google].contains(self) }
}

enum TranslationResultPhase: Equatable, Sendable {
    case idle
    case loading
    case streaming
    case success
    case failure
    case cancelled
    case skipped

    var isRunning: Bool { self == .loading || self == .streaming }
}

struct DictionaryPronunciation: Equatable, Sendable {
    let label: String
    let value: String

    var displayLabel: String {
        switch label {
        case "美": return L10n.text("dictionary.usLabel")
        case "英": return L10n.text("dictionary.ukLabel")
        case "音标": return L10n.text("pronunciation")
        default: return label
        }
    }
}

struct DictionaryBlock: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
}

struct DictionaryForm: Identifiable, Equatable, Sendable {
    let id: Int
    let label: String
    let value: String
}

struct DictionaryPhrase: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let meanings: [String]
}

struct DictionaryExample: Identifiable, Equatable, Sendable {
    let id: Int
    let source: String
    let translation: String
}

struct DictionaryEntry: Equatable, Sendable {
    let headword: String
    let pronunciations: [DictionaryPronunciation]
    let blocks: [DictionaryBlock]
    let englishDefinitions: [String]
    let forms: [DictionaryForm]
    let labels: [String]
    let phrases: [DictionaryPhrase]
    let examples: [DictionaryExample]
    let rawText: String

    init(
        headword: String,
        pronunciations: [DictionaryPronunciation],
        blocks: [DictionaryBlock],
        englishDefinitions: [String],
        forms: [DictionaryForm],
        labels: [String],
        phrases: [DictionaryPhrase] = [],
        examples: [DictionaryExample] = [],
        rawText: String
    ) {
        self.headword = headword
        self.pronunciations = pronunciations
        self.blocks = blocks
        self.englishDefinitions = englishDefinitions
        self.forms = forms
        self.labels = labels
        self.phrases = phrases
        self.examples = examples
        self.rawText = rawText
    }

    var formattedText: String {
        var parts = [headword]
        if !pronunciations.isEmpty {
            parts.append(pronunciations.map { "\($0.displayLabel) /\($0.value)/" }.joined(separator: "    "))
        }
        if !labels.isEmpty { parts.append(labels.joined(separator: " · ")) }
        parts.append(contentsOf: blocks.map(\.text))
        if !forms.isEmpty {
            parts.append(forms.map { "\($0.label)：\($0.value)" }.joined(separator: " · "))
        }
        parts.append(contentsOf: phrases.map { phrase in
            "\(phrase.title)  \(phrase.meanings.joined(separator: "；"))"
        })
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct TranslationServiceResult: Identifiable, Equatable, Sendable {
    let id: TranslationProviderID
    var title: String
    var subtitle: String
    let isTranslation: Bool
    var phase: TranslationResultPhase
    var text: String
    var dictionaryEntry: DictionaryEntry?
    var issue: LocalizedMessage?
    var errorMessage: String? {
        get { issue?.text }
        set { issue = newValue.map(LocalizedMessage.verbatim) }
    }
    var markdownOutput: MarkdownOutput?
    var appleMissingLanguages: [String] = []

    init(id: TranslationProviderID, title: String, subtitle: String, isTranslation: Bool,
         phase: TranslationResultPhase, text: String, dictionaryEntry: DictionaryEntry?,
         errorMessage: String?, appleMissingLanguages: [String] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.isTranslation = isTranslation
        self.phase = phase
        self.text = text
        self.dictionaryEntry = dictionaryEntry
        issue = errorMessage.map(LocalizedMessage.verbatim)
        self.appleMissingLanguages = appleMissingLanguages
    }
}

struct AppleTranslationRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let generation: UUID
    let text: String
    let sourceIdentifier: String?
    let targetIdentifier: String
    var prepareOnly = false
}

protocol DictionaryServing: Sendable {
    var isAvailable: Bool { get }
    /// Returns nil if the word is not in the dictionary; throws if the dictionary database cannot be read.
    func lookup(_ text: String) async throws -> DictionaryEntry?
}

extension DictionaryServing {
    var isAvailable: Bool { true }
}

enum ECDictionaryPaths {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Seven", directoryHint: .isDirectory)
            .appending(path: "ECDICT", directoryHint: .isDirectory)
    }

    static var database: URL { directory.appending(path: "ecdict.sqlite3", directoryHint: .checkFileSystem) }
}

enum ECDictionaryPack {
    static let sourceVersion = "bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b"
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/skywind3000/ECDICT/\(sourceVersion)/ecdict.csv")!
    static let sourceSHA256 = "1a6947e04785db63613a92e14903cdae7954f7e84860b10e68e5c7cbb3f9c3cf"
    static let schemaVersion = 1
}

struct ECDictionaryRecord: Equatable, Sendable {
    let word: String
    let phonetic: String
    let definition: String
    let translation: String
    let pos: String
    let collins: Int
    let oxford: Bool
    let tag: String
    let bnc: Int?
    let frq: Int?
    let exchange: String
}

struct ECDictionaryService: DictionaryServing {
    let databaseURL: URL

    init(databaseURL: URL = ECDictionaryPaths.database) {
        self.databaseURL = databaseURL
    }

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: databaseURL.fileSystemPath)
    }

    static func normalizedQuery(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"“”‘’()[]{}"))
        guard !value.isEmpty, value.count <= 80, !value.contains("\n") else { return nil }
        guard value.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil else { return nil }
        guard !value.unicodeScalars.contains(where: { scalar in
            (0x3400...0x4DBF).contains(scalar.value) ||
                (0x4E00...0x9FFF).contains(scalar.value) ||
                (0xF900...0xFAFF).contains(scalar.value)
        }) else { return nil }
        guard value.unicodeScalars.allSatisfy({ scalar in
            scalar.properties.isAlphabetic || scalar.properties.numericType != nil ||
                " '-.".unicodeScalars.contains(scalar)
        }) else { return nil }
        guard value.split(whereSeparator: { $0.isWhitespace }).count <= 4 else { return nil }
        return value
    }

    func lookup(_ text: String) async throws -> DictionaryEntry? {
        guard let query = Self.normalizedQuery(text), isAvailable else { return nil }
        let url = databaseURL
        return try await Task.detached(priority: .userInitiated) {
            guard let record = try ECDictionaryDatabase.query(url: url, word: query) else { return nil }
            return ECDictionaryEntryParser.parse(record)
        }.value
    }
}

enum ECDictionaryEntryParser {
    static func parse(_ record: ECDictionaryRecord) -> DictionaryEntry {
        let translations = lines(unescaped(record.translation))
        let definitions = lines(unescaped(record.definition))
        let blocks = translations.enumerated().map { index, line in
            DictionaryBlock(id: index, text: line)
        }
        let pronunciation = record.phonetic.trimmingCharacters(in: .whitespacesAndNewlines)
        return DictionaryEntry(
            headword: record.word,
            pronunciations: pronunciation.isEmpty ? [] : [.init(label: "音标", value: pronunciation)],
            blocks: blocks,
            englishDefinitions: definitions,
            forms: forms(record.exchange),
            labels: labels(record),
            rawText: ([record.translation, record.definition, record.exchange]
                .filter { !$0.isEmpty }
                .joined(separator: "\n"))
        )
    }

    private static func lines(_ value: String) -> [String] {
        value.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func unescaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\n")
    }

    private static func forms(_ exchange: String) -> [DictionaryForm] {
        let names = [
            "0": "原形", "p": "过去式", "d": "过去分词",
            "i": "现在分词", "3": "第三人称单数", "r": "比较级",
            "t": "最高级", "s": "复数", "f": "复数"
        ]
        var result: [DictionaryForm] = []
        for component in exchange.split(separator: "/") {
            let pair = component.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2, let label = names[pair[0]], !pair[1].isEmpty else { continue }
            guard !result.contains(where: { $0.label == label && $0.value == pair[1] }) else { continue }
            result.append(.init(id: result.count, label: label, value: pair[1]))
        }
        return result
    }

    private static func labels(_ record: ECDictionaryRecord) -> [String] {
        let tagNames = [
            "zk": "中考", "gk": "高考", "cet4": "四级", "cet6": "六级",
            "ky": "考研", "toefl": "TOEFL", "ielts": "IELTS", "gre": "GRE"
        ]
        var result = record.tag.split(separator: " ").compactMap { tagNames[String($0).lowercased()] }
        if record.oxford { result.append("牛津 3000") }
        if record.collins > 0 { result.append("柯林斯 \(record.collins) 星") }
        if let frq = record.frq, frq > 0 { result.append("当代词频 #\(frq)") }
        return result
    }
}

enum ECDictionaryError: LocalizableIssue {
    case database(String)
    case couldNotOpenDatabase
    case couldNotCreateDatabase
    case invalidPack
    case malformedCSV(Int)
    case network

    var issue: LocalizedMessage {
        switch self {
        case .database(let text): return .key("dictionaryDatabaseError", .text(text))
        case .couldNotOpenDatabase: return .key("dictionaryDatabaseError", .key("couldNotOpenTheOfflineDictionary"))
        case .couldNotCreateDatabase: return .key("dictionaryDatabaseError", .key("couldNotCreateTheOfflineDictionary"))
        case .invalidPack: return .key("theDictionaryFilesFailedVerificationDownloadThem")
        case .malformedCSV(let line): return .key("invalidDictionaryFileFormatAtRecord", .text(String(describing: line)))
        case .network: return .key("couldNotDownloadTheDictionaryCheckYour")
        }
    }

    /// Fixed diagnostic log category without any associated text.
    var diagnosticCategory: String {
        switch self {
        case .database, .couldNotOpenDatabase, .couldNotCreateDatabase: return "database"
        case .invalidPack: return "invalid_pack"
        case .malformedCSV: return "malformed_csv"
        case .network: return "network"
        }
    }
}

enum ECDictionaryDatabase {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func query(url: URL, word: String) throws -> ECDictionaryRecord? {
        guard let database = open(url: url, flags: SQLITE_OPEN_READONLY) else {
            throw ECDictionaryError.couldNotOpenDatabase
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT word, phonetic, definition, translation, pos, collins, oxford, tag, bnc, frq, exchange
        FROM entries
        WHERE word = ? COLLATE NOCASE OR sw = ?
        ORDER BY CASE WHEN word = ? COLLATE NOCASE THEN 0 ELSE 1 END,
                 length(word), COALESCE(frq, 2147483647)
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError(database)
        }
        defer { sqlite3_finalize(statement) }
        bind(word, to: statement, index: 1)
        bind(stripWord(word), to: statement, index: 2)
        bind(word, to: statement, index: 3)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: break
        case SQLITE_DONE: return nil
        default: throw databaseError(database)
        }
        return ECDictionaryRecord(
            word: text(statement, 0),
            phonetic: text(statement, 1),
            definition: text(statement, 2),
            translation: text(statement, 3),
            pos: text(statement, 4),
            collins: Int(sqlite3_column_int(statement, 5)),
            oxford: sqlite3_column_int(statement, 6) != 0,
            tag: text(statement, 7),
            bnc: optionalInt(statement, 8),
            frq: optionalInt(statement, 9),
            exchange: text(statement, 10)
        )
    }

    static func metadata(url: URL) -> (count: Int, sourceSHA256: String)? {
        guard let database = open(url: url, flags: SQLITE_OPEN_READONLY) else { return nil }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT entry_count, source_sha256 FROM metadata WHERE schema_version = ? LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(ECDictionaryPack.schemaVersion))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return (Int(sqlite3_column_int64(statement, 0)), text(statement, 1))
    }

    static func open(
        url: URL,
        flags: Int32,
        openConnection: (UnsafePointer<CChar>, UnsafeMutablePointer<OpaquePointer?>, Int32, UnsafePointer<CChar>?) -> Int32 = sqlite3_open_v2,
        closeConnection: (OpaquePointer) -> Int32 = sqlite3_close
    ) -> OpaquePointer? {
        var database: OpaquePointer?
        let status = openConnection(url.fileSystemPath, &database, flags | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK else {
            // SQLite may still allocate a handle even when sqlite3_open fails.
            if let database { _ = closeConnection(database) }
            return nil
        }
        return database
    }

    static func stripWord(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        })
    }

    fileprivate static func bind(_ value: String, to statement: OpaquePointer, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    fileprivate static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private static func optionalInt(_ statement: OpaquePointer, _ column: Int32) -> Int? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(statement, column))
    }

    fileprivate static func databaseError(_ database: OpaquePointer) -> ECDictionaryError {
        .database(String(cString: sqlite3_errmsg(database)))
    }
}

enum ECDictionaryCSV {
    static func read(
        url: URL,
        onProgress: @escaping (Double) -> Void,
        row: ([String]) throws -> Void
    ) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var fields: [String] = []
            var field: [UInt8] = []
            var quoted = false
            var index = 0
            var records = 0

            func finishField() {
                fields.append(String(decoding: field, as: UTF8.self))
                field.removeAll(keepingCapacity: true)
            }

            func finishRecord() throws {
                finishField()
                if fields.count == 1, fields[0].isEmpty {
                    fields.removeAll(keepingCapacity: true)
                    return
                }
                records += 1
                try row(fields)
                fields.removeAll(keepingCapacity: true)
                if records % 5_000 == 0 { onProgress(Double(index) / Double(max(bytes.count, 1))) }
            }

            while index < bytes.count {
                try Task.checkCancellation()
                let byte = bytes[index]
                if quoted {
                    if byte == 0x22 {
                        if index + 1 < bytes.count, bytes[index + 1] == 0x22 {
                            field.append(0x22)
                            index += 1
                        } else {
                            quoted = false
                        }
                    } else {
                        field.append(byte)
                    }
                } else {
                    switch byte {
                    case 0x22 where field.isEmpty: quoted = true
                    case 0x2C: finishField()
                    case 0x0A: try finishRecord()
                    case 0x0D: break
                    default: field.append(byte)
                    }
                }
                index += 1
            }
            if !field.isEmpty || !fields.isEmpty { try finishRecord() }
            onProgress(1)
        }
    }
}

enum ECDictionaryImporter {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func importCSV(
        from csvURL: URL,
        to databaseURL: URL,
        onProgress: @escaping (Double, Int) -> Void
    ) throws -> Int {
        guard let database = ECDictionaryDatabase.open(url: databaseURL, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) else {
            throw ECDictionaryError.couldNotCreateDatabase
        }
        defer { sqlite3_close(database) }
        try execute(database, "PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA temp_store=MEMORY;")
        try execute(database, """
        CREATE TABLE entries (
            word TEXT PRIMARY KEY COLLATE NOCASE,
            sw TEXT NOT NULL,
            phonetic TEXT,
            definition TEXT,
            translation TEXT,
            pos TEXT,
            collins INTEGER NOT NULL DEFAULT 0,
            oxford INTEGER NOT NULL DEFAULT 0,
            tag TEXT,
            bnc INTEGER,
            frq INTEGER,
            exchange TEXT
        );
        CREATE TABLE metadata (
            schema_version INTEGER NOT NULL,
            source_version TEXT NOT NULL,
            source_sha256 TEXT NOT NULL,
            entry_count INTEGER NOT NULL
        );
        BEGIN IMMEDIATE;
        """)

        let insertSQL = """
        INSERT OR REPLACE INTO entries
        (word, sw, phonetic, definition, translation, pos, collins, oxford, tag, bnc, frq, exchange)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(database, insertSQL, -1, &insert, nil) == SQLITE_OK, let insert else {
            throw ECDictionaryDatabase.databaseError(database)
        }
        defer { sqlite3_finalize(insert) }

        var count = 0
        var isHeader = true
        do {
            try ECDictionaryCSV.read(url: csvURL, onProgress: { progress in
                onProgress(progress, count)
            }) { fields in
                if isHeader { isHeader = false; return }
                guard fields.count >= 13 else { throw ECDictionaryError.malformedCSV(count + 2) }
                let word = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty else { return }
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                let values = [
                    word, ECDictionaryDatabase.stripWord(word), fields[1], fields[2], fields[3], fields[4]
                ]
                for (offset, value) in values.enumerated() {
                    sqlite3_bind_text(insert, Int32(offset + 1), value, -1, transient)
                }
                sqlite3_bind_int(insert, 7, Int32(fields[5]) ?? 0)
                sqlite3_bind_int(insert, 8, Int32(fields[6]) ?? 0)
                sqlite3_bind_text(insert, 9, fields[7], -1, transient)
                bindOptionalInt(fields[8], statement: insert, index: 10)
                bindOptionalInt(fields[9], statement: insert, index: 11)
                sqlite3_bind_text(insert, 12, fields[10], -1, transient)
                guard sqlite3_step(insert) == SQLITE_DONE else {
                    throw ECDictionaryDatabase.databaseError(database)
                }
                count += 1
            }
            try execute(database, "COMMIT; CREATE INDEX entries_sw ON entries(sw, word COLLATE NOCASE);")
            var metadata: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "INSERT INTO metadata VALUES (?, ?, ?, ?)",
                -1,
                &metadata,
                nil
            ) == SQLITE_OK, let metadata else { throw ECDictionaryDatabase.databaseError(database) }
            defer { sqlite3_finalize(metadata) }
            sqlite3_bind_int(metadata, 1, Int32(ECDictionaryPack.schemaVersion))
            sqlite3_bind_text(metadata, 2, ECDictionaryPack.sourceVersion, -1, transient)
            sqlite3_bind_text(metadata, 3, ECDictionaryPack.sourceSHA256, -1, transient)
            sqlite3_bind_int64(metadata, 4, Int64(count))
            guard sqlite3_step(metadata) == SQLITE_DONE else { throw ECDictionaryDatabase.databaseError(database) }
            try execute(database, "PRAGMA optimize;")
            return count
        } catch {
            _ = try? execute(database, "ROLLBACK;")
            throw error
        }
    }

    private static func bindOptionalInt(_ value: String, statement: OpaquePointer, index: Int32) {
        if let integer = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            sqlite3_bind_int(statement, index, integer)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw ECDictionaryDatabase.databaseError(database)
        }
    }
}

enum ECDictionaryInstallationState: Equatable {
    case notInstalled
    case downloading
    case verifying
    case importing
    case ready
    case failed(LocalizedMessage)
}

@MainActor
final class ECDictionaryManager: ObservableObject {
    @Published private(set) var state: ECDictionaryInstallationState = .notInstalled
    @Published private(set) var progress: Double = 0
    @Published private(set) var entryCount = 0
    @Published private(set) var installedBytes: Int64 = 0

    private let databaseURL: URL
    private var installTask: Task<Void, Never>?

    init(databaseURL: URL = ECDictionaryPaths.database) {
        self.databaseURL = databaseURL
        refresh()
    }


    var statusText: String {
        switch state {
        case .notInstalled: return L10n.text("notDownloadedAbout63MBToDownload")
        case .downloading: return L10n.text("downloadingDictionary")
        case .verifying: return L10n.text("verifyingDictionary")
        case .importing: return L10n.format("buildingIndexEntries", String(describing: entryCount.formatted()))
        case .ready: return L10n.format("availableOfflineEntries", String(describing: entryCount.formatted()), String(describing: installedBytes.fileSize()))
        case .failed(let message): return message.text
        }
    }

    func install() {
        installTask?.cancel()
        progress = 0
        entryCount = 0
        state = .downloading
        installTask = Task { [weak self] in
            guard let self else { return }
            let manager = FileManager.default
            let csvURL = manager.temporaryDirectory.appending(path: "seven-ecdict-\(UUID().uuidString).csv", directoryHint: .checkFileSystem)
            let stagingURL = manager.temporaryDirectory.appending(path: "seven-ecdict-\(UUID().uuidString).sqlite3", directoryHint: .checkFileSystem)
            defer {
                try? manager.removeItem(at: csvURL)
                try? manager.removeItem(at: stagingURL)
            }
            do {
                var request = URLRequest(url: ECDictionaryPack.sourceURL)
                // Used only for GitHub ECDICT downloads; unrelated to Youdao browser UA or request signing.
                request.setValue("DictionaryPackClient/1.0", forHTTPHeaderField: "User-Agent")
                let (temporaryURL, response) = try await URLSession.shared.download(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw ECDictionaryError.network
                }
                try manager.copyItem(at: temporaryURL, to: csvURL)
                state = .verifying
                let digest = try await Task.detached { try fileSHA256(csvURL) }.value
                guard digest == ECDictionaryPack.sourceSHA256 else { throw ECDictionaryError.invalidPack }
                state = .importing
                let count = try await Task.detached { [weak self] in
                    try ECDictionaryImporter.importCSV(from: csvURL, to: stagingURL) { progress, count in
                        Task { @MainActor [weak self] in
                            self?.progress = progress
                            self?.entryCount = count
                        }
                    }
                }.value
                try Task.checkCancellation()
                try manager.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if manager.fileExists(atPath: databaseURL.fileSystemPath) {
                    _ = try manager.replaceItemAt(databaseURL, withItemAt: stagingURL)
                } else {
                    try manager.moveItem(at: stagingURL, to: databaseURL)
                }
                entryCount = count
                refresh()
            } catch is CancellationError {
                refresh()
            } catch {
                state = .failed(.forError(error))
            }
            installTask = nil
        }
    }

    func cancel() {
        installTask?.cancel()
        installTask = nil
        refresh()
    }

    func delete() {
        cancel()
        let manager = FileManager.default
        try? manager.removeItem(at: databaseURL)
        try? manager.removeItem(at: URL(filePath: databaseURL.fileSystemPath + "-wal", directoryHint: .checkFileSystem))
        try? manager.removeItem(at: URL(filePath: databaseURL.fileSystemPath + "-shm", directoryHint: .checkFileSystem))
        refresh()
    }

    func refresh() {
        guard let metadata = ECDictionaryDatabase.metadata(url: databaseURL),
              metadata.sourceSHA256 == ECDictionaryPack.sourceSHA256 else {
            state = .notInstalled
            progress = 0
            entryCount = 0
            installedBytes = 0
            return
        }
        entryCount = metadata.count
        installedBytes = (try? databaseURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        progress = 1
        state = .ready
    }
}

private func fileSHA256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while true {
        try Task.checkCancellation()
        let data = try handle.read(upToCount: 1_048_576) ?? Data()
        if data.isEmpty { break }
        hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

private extension Int {
    func formatted() -> String { NumberFormatter.localizedString(from: NSNumber(value: self), number: .decimal) }
}

private extension Int64 {
    func fileSize() -> String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
