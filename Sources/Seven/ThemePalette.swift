import AppKit
import SwiftUI

enum ThemeVariant: String, CaseIterable {
    case light, dark

    init(_ appearance: NSAppearance?) {
        self = appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

enum ThemeToken: String, CaseIterable {
    case surface
    case surfaceRaised
    case surfaceInset
    case blockFill
    case alternateFill
    case ink
    case inkSecondary
    case inkMuted
    case placeholder
    case accent
    case accentFill
    case accentInk
    case onAccent
    case link
    case separator
    case segmentFill
    case segmentSelectedFill
    case focusStroke
    case controlHoverFill
    case controlPressedFill
    case sidebarSelectionFill
    case selectionFill
    case switchFill
    case favorite
    case warning
    case error
    case permissionGranted
    case captureAccent
    case hudBackground
    case hudText
    case hudSecondary
    case hudBorder
    case hudHighlight
}

/// Shared color set used by both AppKit and SwiftUI.
struct ThemePalette: Equatable {
    let id: String
    let variant: ThemeVariant
    let systemColorRevision: UInt64
    private let colors: [ThemeToken: NSColor]

    var isSystem: Bool { id == Self.systemID }

    init(id: String, variant: ThemeVariant, colors: [ThemeToken: NSColor], systemColorRevision: UInt64 = 0) {
        self.id = id
        self.variant = variant
        self.colors = colors
        self.systemColorRevision = systemColorRevision
    }

    subscript(_ token: ThemeToken) -> NSColor { colors[token] ?? Self.nativeColors[token]?() ?? Self.clear }

    var swiftUI: SwiftUIColors { SwiftUIColors(palette: self) }

    @dynamicMemberLookup
    struct SwiftUIColors {
        let palette: ThemePalette

        subscript(dynamicMember key: KeyPath<ThemePalette, NSColor>) -> Color {
            Color(nsColor: palette[keyPath: key])
        }
    }

    struct Swatch {
        let surface: NSColor
        let accent: NSColor
        let border: NSColor

        init(surface: NSColor, ink: NSColor, accent: NSColor) {
            self.surface = surface
            self.accent = accent
            if let base = ThemeColor(nsColor: surface), let text = ThemeColor(nsColor: ink) {
                border = base.mixed(with: text.withOpacity(1), fraction: 0.16).nsColor
            } else {
                border = ink
            }
        }
    }

    var swatch: Swatch {
        var sample = Swatch(surface: surface, ink: ink, accent: accent)
        let mode: AppearanceMode = variant == .dark ? .dark : .light
        mode.appearance?.performAsCurrentDrawingAppearance {
            let resolvedSurface = surface.usingColorSpace(.sRGB) ?? surface
            let resolvedInk = (ink.usingColorSpace(.sRGB) ?? ink).withAlphaComponent(1)
            let resolvedAccent = accent.usingColorSpace(.sRGB) ?? accent
            sample = Swatch(surface: resolvedSurface, ink: resolvedInk, accent: resolvedAccent)
        }
        return sample
    }

    static let systemID = "system"
    static let system = ThemePalette(id: systemID, variant: .light, colors: [:])
    static let clear = NSColor.clear
    static let nativeInsertionPoint = NSColor.textInsertionPointColor
    static let nativeControlInk = NSColor.controlTextColor
    static let nativeTextInk = NSColor.textColor
    static let nativeTextSelection: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.selectedTextColor, .backgroundColor: NSColor.selectedTextBackgroundColor
    ]
    static let transparent = Color.clear

    var surface: NSColor { self[.surface] }
    var surfaceRaised: NSColor { self[.surfaceRaised] }
    var surfaceInset: NSColor { self[.surfaceInset] }
    var blockFill: NSColor { self[.blockFill] }
    var alternateFill: NSColor { self[.alternateFill] }
    var ink: NSColor { self[.ink] }
    var inkSecondary: NSColor { self[.inkSecondary] }
    var inkMuted: NSColor { self[.inkMuted] }
    var placeholder: NSColor { self[.placeholder] }
    var accent: NSColor { self[.accent] }
    var accentFill: NSColor { self[.accentFill] }
    var accentInk: NSColor { self[.accentInk] }
    var onAccent: NSColor { self[.onAccent] }
    var link: NSColor { self[.link] }
    var separator: NSColor { self[.separator] }
    var focusStroke: NSColor { self[.focusStroke] }
    var controlHoverFill: NSColor { self[.controlHoverFill] }
    var controlPressedFill: NSColor { self[.controlPressedFill] }
    var sidebarSelectionFill: NSColor { self[.sidebarSelectionFill] }
    var selectionFill: NSColor { self[.selectionFill] }
    var switchFill: NSColor { self[.switchFill] }
    var favorite: NSColor { self[.favorite] }
    var warning: NSColor { self[.warning] }
    var error: NSColor { self[.error] }
    var permissionGranted: NSColor { self[.permissionGranted] }
    var captureAccent: NSColor { self[.captureAccent] }
    var hudBackground: NSColor { self[.hudBackground] }
    var hudText: NSColor { self[.hudText] }
    var hudSecondary: NSColor { self[.hudSecondary] }
    var hudBorder: NSColor { self[.hudBorder] }
    var hudHighlight: NSColor { self[.hudHighlight] }
    var commonLanguageRowFill: NSColor { Self.clear }
    var commonLanguageAlternateRowFill: NSColor { self[.alternateFill] }
    var warningFill: NSColor { scaled(self[.warning], by: 0.07, name: "SevenWarningFill") }
    var warningStroke: NSColor { scaled(self[.warning], by: 0.16, name: "SevenWarningStroke") }
    var keycapFixedFill: NSColor { isSystem ? alternateFill : ink.withAlphaComponent(0.1) }
    var keycapFill: NSColor { isSystem ? surfaceRaised : ink.withAlphaComponent(0.1) }
    var keycapStroke: NSColor { isSystem ? scaled(self[.inkSecondary], by: 0.3, name: "SevenKeycapStroke") : self[.separator] }
    var keycapSuccessStroke: NSColor { scaled(self[.accent], by: 0.7, name: "SevenKeycapSuccessStroke") }
    var keycapEmptyStroke: NSColor { scaled(self[.inkSecondary], by: 0.5, name: "SevenKeycapEmptyStroke") }
    var keycapShadow: NSColor { scaled(isSystem ? .shadowColor : self[.ink], by: 0.12, name: "SevenKeycapShadow") }
    var brandTileStroke: NSColor { scaled(self[.ink], by: 0.12, name: "SevenBrandTileStroke") }
    var permissionCardFill: NSColor { isSystem ? scaled(self[.surfaceRaised], by: 0.65, name: "SevenPermissionCardFill") : self[.surfaceRaised] }
    var permissionCardStroke: NSColor { isSystem ? scaled(self[.ink], by: 0.085, name: "SevenPermissionCardStroke") : self[.separator] }
    var segmentFill: NSColor { self[.segmentFill] }
    var segmentSelectedFill: NSColor { self[.segmentSelectedFill] }
    var screenshotSizeFieldFill: NSColor { isSystem ? segmentFill : surfaceInset }
    var disabledInk: NSColor { isSystem ? .disabledControlTextColor : self[.inkMuted] }
    var toolbarSelectionFill: NSColor { isSystem ? scaled(.controlAccentColor, by: 0.14, name: "SevenToolbarSelection") : self[.controlPressedFill] }
    var annotationHandle: NSColor { isSystem ? .white : surfaceRaised }
    var highlighterCursorOuter: NSColor { isSystem ? .white : onAccent }
    var highlighterCursorInner: NSColor { isSystem ? .black : accentFill }
    var toolbarSwatchBorder: NSColor { isSystem ? .white : self[.separator] }
    var sliderAccent: NSColor { accent }
    var captureCrosshair: NSColor { captureAccent.withAlphaComponent(0.5) }
    var captureMagnifierBorder: NSColor { captureAccent }
    var pinCloseInk: NSColor { isSystem ? .black : self[.ink] }
    var pinCloseFill: NSColor { isSystem ? .white : self[.surfaceRaised] }
    var menuSelectedText: NSColor { isSystem ? .selectedMenuItemTextColor : self[.onAccent] }

    /// Reads system semantic colors on each access, deriving secondary colors from their current values.
    private static let nativeColors: [ThemeToken: () -> NSColor] = [
        .surface: { .windowBackgroundColor },
        .surfaceRaised: { .controlBackgroundColor },
        .surfaceInset: { .textBackgroundColor },
        .blockFill: { .tertiarySystemFill },
        .alternateFill: { .quaternarySystemFill },
        .ink: { .labelColor },
        .inkSecondary: { .secondaryLabelColor },
        .inkMuted: { .tertiaryLabelColor },
        .placeholder: { .placeholderTextColor },
        .accent: { .controlAccentColor },
        .accentFill: { .controlAccentColor },
        .accentInk: { .controlAccentColor },
        .onAccent: { .alternateSelectedControlTextColor },
        .link: { .linkColor },
        .separator: { .separatorColor },
        .segmentFill: { .secondarySystemFill },
        .segmentSelectedFill: { .controlBackgroundColor },
        .focusStroke: { scaled(.controlAccentColor, by: 0.35, name: "SevenFocusStroke") },
        .controlHoverFill: { .tertiarySystemFill },
        .controlPressedFill: { .secondarySystemFill },
        .sidebarSelectionFill: { .unemphasizedSelectedContentBackgroundColor },
        .selectionFill: { .selectedTextBackgroundColor },
        .switchFill: { .controlAccentColor },
        .favorite: { .systemYellow },
        .warning: { .systemOrange },
        .error: { .systemRed },
        .captureAccent: { .controlAccentColor },
        .hudBackground: { .windowBackgroundColor },
        .hudText: { .labelColor },
        .hudSecondary: { .secondaryLabelColor },
        .hudBorder: { .separatorColor },
        .hudHighlight: { .controlAccentColor },
        .permissionGranted: { .systemGreen }
    ]

    static func rgb(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    private func scaled(_ color: NSColor, by factor: CGFloat, name: String) -> NSColor {
        isSystem ? Self.scaled(color, by: factor, name: name) : color.withAlphaComponent(color.alphaComponent * factor)
    }

    /// Preserves the original alpha of the system color.
    private static func scaled(_ color: NSColor, by factor: CGFloat, name: String) -> NSColor {
        NSColor(name: name) { appearance in
            var resolved = color
            appearance.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB) ?? color
            }
            return resolved.withAlphaComponent(resolved.alphaComponent * factor)
        }
    }
}
