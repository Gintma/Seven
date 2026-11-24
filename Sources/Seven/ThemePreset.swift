struct ThemePreset: Identifiable {
    let id: String
    let title: String
    let light: ThemeSeed?
    let dark: ThemeSeed?

    func seed(for variant: ThemeVariant) -> ThemeSeed? { variant == .light ? light : dark }

    func palette(for variant: ThemeVariant) -> ThemePalette {
        guard let seed = seed(for: variant) else { return ThemeResolver.system(variant) }
        return ThemeResolver.resolve(seed, id: id, variant: variant)
    }

    func swatch(for variant: ThemeVariant) -> ThemePalette.Swatch {
        guard let seed = seed(for: variant) else { return ThemeResolver.system(variant).swatch }
        return ThemePalette.Swatch(surface: seed.surface.nsColor, ink: seed.ink.nsColor, accent: seed.accent.nsColor)
    }

    static let system = ThemePreset(id: ThemePalette.systemID, title: "系统默认", light: nil, dark: nil)

    static func choices(for variant: ThemeVariant) -> [Self] {
        [system] + imported.filter { $0.seed(for: variant) != nil }
    }

    static func resolve(_ id: String?, for variant: ThemeVariant) -> Self {
        imported.first { $0.id == id && $0.seed(for: variant) != nil } ?? system
    }
}
