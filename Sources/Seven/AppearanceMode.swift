import AppKit

/// Appearance preference: follow system, or force Light or Dark Mode.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearanceMode.v1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.text("followSystem")
        case .light: return L10n.text("light")
        case .dark: return L10n.text("dark")
        }
    }

    /// nil means follow the system appearance.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> AppearanceMode {
        defaults.string(forKey: storageKey).flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }
}
