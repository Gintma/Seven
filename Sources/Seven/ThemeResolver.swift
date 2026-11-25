enum ThemeResolver {
    static func system(_ variant: ThemeVariant, colorRevision: UInt64 = 0) -> ThemePalette {
        ThemePalette(id: ThemePalette.systemID, variant: variant, colors: [:], systemColorRevision: colorRevision)
    }

    static func resolve(_ seed: ThemeSeed, id: String, variant: ThemeVariant) -> ThemePalette {
        let surface = seed.surface
        let contrast = min(max(seed.contrast / 100, 0), 1)
        let accent = seed.tokens[.accent] ?? seed.accent
        let block = distinctPanel(seed.tokens[.blockFill] ?? surface.mixed(with: seed.ink, fraction: 0.02 + contrast * 0.04),
                                  surface: surface, ink: seed.ink)
        let raised = seed.tokens[.surfaceRaised] ?? surface.mixed(with: seed.ink, fraction: 0.04 + contrast * 0.1)
        let inset = seed.tokens[.surfaceInset] ?? surface.mixed(with: seed.ink, fraction: 0.03 + contrast * 0.06)
        // 两种外观都用凹暗轨道和较亮的滑块，分别适配卡片与工具条底色。
        let segmentTrack = variant == .dark
            ? surface.mixed(with: 0x000000, fraction: 0.24)
            : surface.mixed(with: seed.ink, fraction: 0.10)
        let segmentThumb = variant == .dark
            ? raised.mixed(with: seed.ink, fraction: 0.12)
            : raised.mixed(with: 0xFFFFFF, fraction: 0.35)
        let backgrounds = [surface, block, raised, inset]
        let ink = readable(seed.ink, on: backgrounds + [segmentThumb], minimum: 4.5)
        let secondary = readable(seed.tokens[.inkSecondary] ?? ink.withOpacity(0.58 + contrast * 0.2),
                                 on: backgrounds + [segmentTrack], minimum: 4.5)
        let muted = readable(seed.tokens[.inkMuted] ?? ink.withOpacity(0.48), on: backgrounds, minimum: 3)
        let accentFill = seed.tokens[.accentFill] ?? accent
        let preferredOnAccent = seed.tokens[.onAccent] ?? (variant == .dark ? 0x000000 : 0xFFFFFF)
        let onAccent = readable(preferredOnAccent, on: [accentFill], minimum: 4.5)
        // 次级按钮的悬停底色也作为侧栏选中底色的默认值。
        let controlHoverFill = seed.tokens[.controlHoverFill] ?? ink.withOpacity(0.07)
        let selection = seed.tokens[.selectionFill] ?? accent.withOpacity(0.25)
        let link = readable(seed.tokens[.accentInk] ?? accent, on: backgrounds, minimum: 4.5)
        let warning = readable(seed.semantic[.warning] ?? (variant == .dark ? 0xEBAF63 : 0x995108),
                               on: backgrounds, minimum: 4.5)
        let error = readable(seed.semantic[.error] ?? (variant == .dark ? 0xFF807C : 0xB2272D),
                             on: backgrounds, minimum: 4.5)
        let favorite = readable(seed.semantic[.favorite] ?? (variant == .dark ? 0xF2CA67 : 0x906200),
                                on: backgrounds, minimum: 3)
        let hudBackground = raised.mixed(with: accent, fraction: 0.04)
        let colors: [ThemeToken: ThemeColor] = [
            .surface: surface, .surfaceRaised: raised, .surfaceInset: inset, .blockFill: block,
            .alternateFill: seed.tokens[.alternateFill] ?? ink.withOpacity(0.035),
            .ink: ink, .inkSecondary: secondary, .inkMuted: muted, .placeholder: muted,
            .accent: accent, .accentFill: accentFill, .accentInk: link, .onAccent: onAccent, .link: link,
            .separator: seed.tokens[.separator] ?? ink.withOpacity(0.12),
            .segmentFill: segmentTrack, .segmentSelectedFill: segmentThumb,
            .focusStroke: seed.tokens[.focusStroke] ?? link,
            .controlHoverFill: controlHoverFill,
            .sidebarSelectionFill: controlHoverFill,
            .controlPressedFill: seed.tokens[.controlPressedFill] ?? ink.withOpacity(0.11),
            .selectionFill: selection, .switchFill: seed.tokens[.switchFill] ?? accentFill,
            .favorite: favorite, .warning: warning, .error: error, .captureAccent: accent,
            .hudBackground: hudBackground, .hudText: readable(ink, on: [hudBackground], minimum: 4.5),
            .hudSecondary: readable(secondary, on: [hudBackground], minimum: 4.5),
            .hudBorder: hudBackground.mixed(with: ink, fraction: 0.16),
            .hudHighlight: readable(link, on: [hudBackground], minimum: 4.5)
        ]
        let resolved = colors.merging(seed.overrides) { _, override in override }
        return ThemePalette(id: id, variant: variant, colors: resolved.mapValues(\.nsColor))
    }

    /// 页底与内容卡片只差不到一个可见色阶时，用同色系补出层级。
    private static func distinctPanel(_ panel: ThemeColor, surface: ThemeColor, ink: ThemeColor) -> ThemeColor {
        panel.contrast(against: surface) < 1.025 ? surface.mixed(with: ink, fraction: 0.035) : panel
    }

    /// 保留原色，必要时只混入足够的黑或白，保证文字跨各实色表面可读。
    private static func readable(_ original: ThemeColor, on backgrounds: [ThemeColor], minimum: Double) -> ThemeColor {
        func contrast(_ color: ThemeColor) -> Double {
            backgrounds.map { color.contrast(against: $0) }.min() ?? minimum
        }
        guard contrast(original) < minimum else { return original }
        let black: ThemeColor = 0x000000
        let white: ThemeColor = 0xFFFFFF
        let target = contrast(black) > contrast(white) ? black : white
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<18 {
            let fraction = (lower + upper) / 2
            if contrast(original.mixed(with: target, fraction: fraction)) >= minimum { upper = fraction }
            else { lower = fraction }
        }
        return original.mixed(with: target, fraction: upper)
    }
}
