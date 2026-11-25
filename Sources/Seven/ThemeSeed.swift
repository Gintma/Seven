/// 色板的原始输入。预设角色可由纯计算补齐，手动覆盖在最后应用。
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
