import Foundation

struct TranslationRecord: Codable, Identifiable, Equatable, Sendable {
    struct Reference: Equatable {
        let id: UUID
        let createdAt: Date
    }

    struct Result: Codable, Identifiable, Equatable, Sendable {
        let providerID: TranslationProviderID
        let providerName: String
        let translatedText: String

        var id: TranslationProviderID { providerID }
        var hasContent: Bool { translatedText.contains { !$0.isWhitespace } }
    }

    let id: UUID
    let sourceText: String
    let sourceLanguage: String
    let targetLanguage: String
    let mode: TranslationMode
    let createdAt: Date
    var results: [Result]

    var reference: Reference { Reference(id: id, createdAt: createdAt) }

    func matches(search: String) -> Bool {
        search.isEmpty || sourceText.localizedCaseInsensitiveContains(search) ||
            results.contains { $0.translatedText.localizedCaseInsensitiveContains(search) }
    }
}

enum HistoryCollection: String, CaseIterable, Identifiable {
    case history, favorites

    var id: Self { self }
    var title: String { L10n.text(self == .history ? "history.title" : "history.favorites") }
    var icon: String { self == .history ? "clock" : "star" }
    var emptyMessage: String { L10n.text(self == .history ? "noHistoryYet" : "history.noFavorites") }
    var exportNameKey: String { self == .history ? "sevenHistory" : "history.favoritesExportName" }
    var clearTitle: String { L10n.text(self == .history ? "clearHistory" : "history.clearFavorites") }
    var clearConfirmation: String { L10n.text(self == .history ? "clearAllHistory" : "history.clearAllFavorites") }
}

enum HistoryRetention: Int, CaseIterable {
    case oneHundred = 100
    case threeHundred = 300
    case fiveHundred = 500
    case oneThousand = 1000
    case unlimited = 0

    var limit: Int? { self == .unlimited ? nil : rawValue }
    var title: String {
        limit.map { L10n.format("history.retainedCount", Int64($0)) } ?? L10n.text("history.unlimited")
    }
}
