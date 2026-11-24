import AppKit
import Combine
import Observation

@MainActor
protocol ThemeApplying: AnyObject {
    func applyTheme(_ palette: ThemePalette)
}

/// 应用外观与当前色板的唯一状态源。
@MainActor @Observable
final class ThemeManager {
    static let shared = ThemeManager()

    static let lightThemeKey = "appearanceTheme.light.v1"
    static let darkThemeKey = "appearanceTheme.dark.v1"

    private let defaults: UserDefaults
    private let observers = NSHashTable<AnyObject>.weakObjects()
    @ObservationIgnored private weak var application: NSApplication?
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private var systemColorsObservation: AnyCancellable?
    private(set) var appearanceMode: AppearanceMode
    private(set) var lightThemeID: String
    private(set) var darkThemeID: String
    private(set) var palette: ThemePalette

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let mode = AppearanceMode.stored(in: defaults)
        appearanceMode = mode
        let light = ThemePreset.resolve(defaults.string(forKey: Self.lightThemeKey), for: .light)
        let dark = ThemePreset.resolve(defaults.string(forKey: Self.darkThemeKey), for: .dark)
        lightThemeID = light.id
        darkThemeID = dark.id
        let variant = ThemeVariant(mode.appearance)
        palette = (variant == .light ? light : dark).palette(for: variant)
    }

    func start(observing application: NSApplication) {
        self.application = application
        application.appearance = appearanceMode.appearance
        refresh()
        appearanceObservation = application.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            // 退出 KVO 回调后再读取最新的有效外观，避免在 AppKit 外观传播期间刷新视图。
            Task { @MainActor [weak self] in self?.refresh() }
        }
        systemColorsObservation = NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh(systemColorsChanged: true) }
            }
    }

    func selectAppearanceMode(_ mode: AppearanceMode) {
        guard mode != appearanceMode else { return }
        appearanceMode = mode
        defaults.set(mode.rawValue, forKey: AppearanceMode.storageKey)
        application?.appearance = mode.appearance
        refresh()
    }

    func themeID(for variant: ThemeVariant) -> String {
        variant == .light ? lightThemeID : darkThemeID
    }

    func selectTheme(_ id: String, for variant: ThemeVariant) {
        let selected = ThemePreset.resolve(id, for: variant).id
        guard selected != themeID(for: variant) else { return }
        switch variant {
        case .light:
            lightThemeID = selected
            defaults.set(selected, forKey: Self.lightThemeKey)
        case .dark:
            darkThemeID = selected
            defaults.set(selected, forKey: Self.darkThemeKey)
        }
        refresh()
    }

    func register(_ observer: any ThemeApplying) {
        observers.add(observer)
        observer.applyTheme(palette)
    }

    private func refresh(systemColorsChanged: Bool = false) {
        let variant = ThemeVariant(appearanceMode.appearance ?? application?.effectiveAppearance)
        let id = themeID(for: variant)
        let refreshSystemColors = systemColorsChanged && id == ThemePalette.systemID
        guard palette.id != id || palette.variant != variant || refreshSystemColors else { return }
        let next: ThemePalette
        if id == ThemePalette.systemID {
            // 系统色对象可能仍相等，递增修订号让 SwiftUI 与 AppKit 都收到更新。
            let revision = palette.systemColorRevision &+ (refreshSystemColors ? 1 : 0)
            next = ThemeResolver.system(variant, colorRevision: revision)
        } else {
            next = ThemePreset.resolve(id, for: variant).palette(for: variant)
        }
        palette = next
        for observer in observers.allObjects {
            (observer as? any ThemeApplying)?.applyTheme(next)
        }
    }
}
