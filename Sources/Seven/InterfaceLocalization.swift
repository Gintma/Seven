import Foundation
import SwiftUI

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"

    static let preferenceKey = "interfaceLanguage.v1"
    var id: Self { self }

    var title: String {
        switch self {
        case .system: return L10n.text("followSystem")
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .spanish: return "Español"
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    static func matchingLocalization(_ identifier: String) -> Self? {
        let language = Locale.Language(identifier: identifier)
        guard let code = language.languageCode?.identifier else { return nil }
        if code == "zh" {
            return language.script?.identifier == "Hant" ? .traditionalChinese : .simplifiedChinese
        }
        return Self(rawValue: code)
    }
}

@MainActor
final class InterfaceLanguageState: ObservableObject {
    static let shared = InterfaceLanguageState(defaults: .standard)
    static let didChange = Notification.Name("Seven.InterfaceLanguageDidChange")

    @Published private(set) var selection: InterfaceLanguage
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        selection = .stored(in: defaults)
    }

    func select(_ language: InterfaceLanguage) {
        guard language != selection else { return }
        defaults.set(language.rawValue, forKey: InterfaceLanguage.preferenceKey)
        selection = language
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

enum L10n {
    @TaskLocal static var languageOverride: InterfaceLanguage?

    private static let systemLanguage: InterfaceLanguage = {
        let main = Bundle.main
        guard let identifier = main.preferredLocalizations.first,
              languageBundle(identifier, in: main) != nil else { return .simplifiedChinese }
        return InterfaceLanguage.matchingLocalization(identifier) ?? .simplifiedChinese
    }()

    private static let bundles: [InterfaceLanguage: Bundle] = {
        let localized = InterfaceLanguage.allCases.filter { $0 != .system }.compactMap { language in
            resourceBundle(for: language).map { (language, $0) }
        }
        return Dictionary(uniqueKeysWithValues: localized)
    }()

    static var language: InterfaceLanguage {
        let selected = languageOverride ?? .stored()
        return selected == .system ? systemLanguage : selected
    }

    static var locale: Locale { Locale(identifier: language.rawValue) }

    static func languageBundle(_ identifier: String, in bundle: Bundle) -> Bundle? {
        let name = bundle.localizations.first { $0.caseInsensitiveCompare(identifier) == .orderedSame } ?? identifier
        return bundle.url(forResource: name, withExtension: "lproj").flatMap(Bundle.init(url:))
    }

    static func resourceBundle(for language: InterfaceLanguage) -> Bundle? {
        // An installed app must find its language files without accessing the SwiftPM build directory.
        resourceBundle(for: language, main: .main) { .module }
    }

    static func resourceBundle(for language: InterfaceLanguage, main: Bundle, package: () -> Bundle) -> Bundle? {
        if let localized = languageBundle(language.rawValue, in: main) { return localized }
        guard main.bundleURL.pathExtension != "app" else { return nil }
        return languageBundle(language.rawValue, in: package())
    }

    private static func lookup(_ key: String, for language: InterfaceLanguage) -> String {
        let value = bundles[language]?.localizedString(forKey: key, value: nil, table: nil)
        if let value, value != key { return value }
        return bundles[.simplifiedChinese]?.localizedString(forKey: key, value: nil, table: nil) ?? key
    }

    static func text(_ key: String) -> String {
        lookup(key, for: language)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, arguments: arguments)
    }

    static func format(_ key: String, arguments: [CVarArg]) -> String {
        let language = language
        return String(format: lookup(key, for: language), locale: Locale(identifier: language.rawValue), arguments: arguments)
    }
}

enum LocalizedMessage: Equatable, Sendable, ExpressibleByStringLiteral {
    enum Argument: Equatable, Sendable {
        case text(String)
        case key(String)
        case language(String)
        case languages([String])
        case provider(ServiceProvider)
        case count(Int)
        case duration(TimeInterval)
        indirect case message(LocalizedMessage)

        var value: CVarArg {
            switch self {
            case .text(let text): return text
            case .key(let key): return L10n.text(key)
            case .language(let code): return LanguageCatalog.name(code)
            case .languages(let codes):
                let names = codes.map(LanguageCatalog.name)
                let formatter = ListFormatter()
                formatter.locale = L10n.locale
                return formatter.string(from: names) ?? names.joined(separator: ", ")
            case .provider(let provider): return provider.title
            case .count(let count): return Int64(count)
            case .duration(let seconds): return seconds
            case .message(let message): return message.text
            }
        }
    }

    case verbatim(String)
    case resource(String, [Argument])

    init(stringLiteral value: String) { self = .verbatim(value) }

    static func key(_ key: String, _ arguments: Argument...) -> Self {
        .resource(key, arguments)
    }

    var text: String {
        switch self {
        case .verbatim(let value): return value
        case .resource(let key, let arguments):
            return arguments.isEmpty ? L10n.text(key) : L10n.format(key, arguments: arguments.map(\.value))
        }
    }

    static func forError(_ error: Error) -> Self {
        (error as? LocalizableIssue)?.issue ?? .verbatim(error.localizedDescription)
    }
}

protocol LocalizableIssue: LocalizedError {
    var issue: LocalizedMessage { get }
}

extension LocalizableIssue {
    var errorDescription: String? { issue.text }
}
