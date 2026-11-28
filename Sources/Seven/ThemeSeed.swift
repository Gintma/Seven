/// Raw palette input. Preset roles can be derived purely by computation, with manual overrides applied last.
struct ThemeSeed {
    enum Semantic {
        case error, warning, favorite
    }

    let surface: ThemeColor
    let ink: ThemeColor
    let accent: ThemeColor
    let contrast: Double
    var semantic: [Semantic: ThemeColor] = [:]
    var tokens: [ThemeToken: ThemeColor] = [:]
    var overrides: [ThemeToken: ThemeColor] = [:]
}
