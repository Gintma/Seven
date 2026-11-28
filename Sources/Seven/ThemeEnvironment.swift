import SwiftUI

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = ThemePalette.system
}

extension EnvironmentValues {
    var theme: ThemePalette {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

@MainActor
struct ThemedContent<Content: View>: View {
    private let manager: ThemeManager
    let content: Content

    init(content: Content, manager: ThemeManager? = nil) {
        self.content = content
        self.manager = manager ?? .shared
    }

    var body: some View {
        let palette = manager.palette
        content
            .environment(\.theme, palette)
            .modifier(ThemeForeground(palette: palette))
    }
}

/// SwiftUI group dividers and standard button backgrounds share the tertiary foreground color.
struct ThemeForeground: ViewModifier {
    let palette: ThemePalette

    func body(content: Content) -> some View {
        if palette.isSystem {
            content.foregroundStyle(ThemeStyle.nativePrimary)
        } else {
            let colors = palette.swiftUI
            content.foregroundStyle(colors.ink, colors.inkSecondary, colors.separator)
        }
    }
}

struct ThemeStyle: ShapeStyle {
    let color: KeyPath<ThemePalette, NSColor> & Sendable
    var native: HierarchicalShapeStyle?

    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        if environment.theme.isSystem, let native {
            return AnyShapeStyle(native)
        }
        return AnyShapeStyle(environment.theme.swiftUI[dynamicMember: color])
    }

    static let nativePrimary = Self(color: \.ink, native: .primary)
    static let nativeSecondary = Self(color: \.inkSecondary, native: .secondary)
    static let ink = Self(color: \.ink)
    static let inkSecondary = Self(color: \.inkSecondary)
    static let placeholder = Self(color: \.placeholder)
    static let accentInk = Self(color: \.accentInk)
    static let favorite = Self(color: \.favorite)
    static let warning = Self(color: \.warning)
    static let error = Self(color: \.error)
    static let background = Self(color: \.surface)
    static let blockFill = Self(color: \.blockFill)
    static let permissionCardFill = Self(color: \.permissionCardFill)
    static let permissionCardStroke = Self(color: \.permissionCardStroke)
}

extension View {
    func themeDetailSurface() -> some View { modifier(ThemeDetailSurface()) }
}

private struct ThemeDetailSurface: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.background(theme.isSystem ? ThemePalette.transparent : theme.swiftUI.surface)
    }
}

struct ThemedDivider: View {
    @Environment(\.theme) private var theme

    var axis: Axis = .horizontal

    var body: some View {
        Group {
            if theme.isSystem {
                Divider()
            } else {
                Rectangle().fill(theme.swiftUI.separator)
                    .frame(width: axis == .vertical ? Design.Layout.dividerWidth : nil,
                           height: axis == .horizontal ? Design.Layout.dividerWidth : nil)
            }
        }
        .accessibilityHidden(true)
    }
}
