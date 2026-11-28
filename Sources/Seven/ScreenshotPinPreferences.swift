import AppKit

enum ScreenshotPinWheel: String, CaseIterable, Identifiable {
    case plain, command, option, shift, control
    var id: Self { self }
    var title: String {
        switch self {
        case .plain: return L10n.text("scroll")
        case .command: return L10n.text("scroll2")
        case .option: return L10n.text("scroll3")
        case .shift: return L10n.text("scroll4")
        case .control: return L10n.text("scroll5")
        }
    }
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .plain: return []
        case .command: return .command
        case .option: return .option
        case .shift: return .shift
        case .control: return .control
        }
    }
    static func available(excluding other: Self) -> [Self] { allCases.filter { $0 != other } }
    func matches(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .option, .shift, .control]) == self.flags
    }
}

/// Persists only pin interaction/display preferences, never pinned images or clipboard content; nil uses an in-memory store for tests.
final class ScreenshotPinPreferences {
    static let zoomKey = "screenshotPin.zoomWheel.v1"
    static let opacityWheelKey = "screenshotPin.opacityWheel.v1"
    var usesPersistentStorage: Bool { defaults != nil }
    private let defaults: UserDefaults?
    init(defaults: UserDefaults? = nil) { self.defaults = defaults }
    var shortcutDefaults:UserDefaults? {defaults}
    var shadowStyle:ScreenshotShadowStyle {ScreenshotShadowPreferences(defaults:defaults).style(.pin)}
    var zoomWheel: ScreenshotPinWheel { defaults?.string(forKey: Self.zoomKey).flatMap(ScreenshotPinWheel.init) ?? .command }
    var opacityWheel: ScreenshotPinWheel { defaults?.string(forKey: Self.opacityWheelKey).flatMap(ScreenshotPinWheel.init) ?? .option }
}

@MainActor enum ScreenshotPinShortcuts {
    static func closeCurrent(defaults:UserDefaults? = .standard)->HotKeyManager {
        HotKeyManager(defaults:defaults,storageKey:"pinCloseHotKey.v1",identifierID:10,actionLabel:"关闭钉图",allowsUnset:true,scope:.local)
    }
    static func closeAll(defaults:UserDefaults? = .standard)->HotKeyManager {
        HotKeyManager(defaults:defaults,storageKey:"pinCloseAllHotKey.v1",identifierID:11,actionLabel:"关闭所有钉图",allowsUnset:true)
    }
}
