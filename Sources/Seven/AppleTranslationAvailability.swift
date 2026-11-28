import Foundation
import Translation

enum AppleTranslationAvailability: Equatable, Sendable {
    case installed, unsupported
    case requiresDownload([String])
}

protocol AppleTranslationAvailabilityChecking: Sendable {
    func availability(source: String, target: String) async -> AppleTranslationAvailability
}

struct SystemAppleTranslationAvailability: AppleTranslationAvailabilityChecking {
    func availability(source: String, target: String) async -> AppleTranslationAvailability {
        guard #available(macOS 15, *) else { return .unsupported }
        let checker = LanguageAvailability()
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        switch await checker.status(from: from, to: to) {
        case .installed: return .installed
        case .unsupported: return .unsupported
        case .supported:
            // The system only reports pair status; an installed edge proves both endpoints are installed.
            // When no installed pair is found, conservatively list unverified languages in the current pair without reading private system files.
            let languages = await checker.supportedLanguages
            var missing: [String] = []
            for code in [source, target] {
                let language = Locale.Language(identifier: code)
                var installed = false
                for other in languages where other != language {
                    if await checker.status(from: language, to: other) == .installed { installed = true; break }
                }
                if !installed && !missing.contains(code) { missing.append(code) }
            }
            return .requiresDownload(missing)
        @unknown default: return .unsupported
        }
    }
}
