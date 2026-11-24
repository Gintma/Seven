import AVFoundation
import Foundation

/// Query installed voices at use time; never let AVSpeechSynthesizer pick an unrelated default voice.
enum SystemSpeechAvailability {
    static func voiceLanguage(for code: String, installed: [String]) -> String? {
        let preferred = LanguageCatalog.language(code)?.speechLocale ?? code
        if let exact = installed.first(where: { $0.caseInsensitiveCompare(preferred) == .orderedSame }) { return exact }
        let base = code.split(separator: "-").first.map(String.init) ?? code
        if base == "zh" {
            let variants = code == "zh-Hant" ? ["zh-TW", "zh-HK", "zh-Hant"] : ["zh-CN", "zh-SG", "zh-Hans"]
            return installed.first { locale in variants.contains { locale.hasPrefix($0) } }
        }
        return installed.first { $0.split(separator: "-").first.map(String.init) == base }
    }

    // Voice enumeration is expensive. Refresh a bounded runtime snapshot instead of querying per language/button.
    private static let lock = NSLock()
    private static var snapshot: (date: Date, languages: [String])?
    static var installedLanguages: [String] {
        lock.lock()
        defer { lock.unlock() }
        if let snapshot, Date().timeIntervalSince(snapshot.date) < 2 { return snapshot.languages }
        let languages = AVSpeechSynthesisVoice.speechVoices().map(\.language)
        snapshot = (Date(), languages)
        return languages
    }
}
