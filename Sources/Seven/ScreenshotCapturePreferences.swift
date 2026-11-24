import Foundation

enum ScreenshotDoubleClickAction:String,CaseIterable,Identifiable {
    case copy,save,pin,none
    var id:Self {self}
    var title:String {switch self {case .copy:return L10n.text("copy");case .save:return L10n.text("save");case .pin:return L10n.text("pinImage");case .none:return L10n.text("takeNoAction")}}
}
final class ScreenshotCapturePreferences {
    static let crosshairKey="screenshotCapture.crosshair.v1",magnifierKey="screenshotCapture.magnifier.v1",hintsKey="screenshotCapture.hints.v1",doubleClickKey="screenshotCapture.doubleClick.v1"
    static let completionSoundKey="screenshotCapture.completionSound.v1"
    private let defaults:UserDefaults?
    init(defaults:UserDefaults? = nil){self.defaults=defaults}
    var completionSound:Bool {defaults?.object(forKey:Self.completionSoundKey) as? Bool ?? true}
    var crosshair:Bool {defaults?.object(forKey:Self.crosshairKey) as? Bool ?? true}
    var magnifier:Bool {defaults?.object(forKey:Self.magnifierKey) as? Bool ?? true}
    var hints:Bool {defaults?.object(forKey:Self.hintsKey) as? Bool ?? true}
    var doubleClick:ScreenshotDoubleClickAction {defaults?.string(forKey:Self.doubleClickKey).flatMap(ScreenshotDoubleClickAction.init(rawValue:)) ?? .copy}
}
