import AppKit
import SwiftUI

/// Seven's design tokens: single source of truth for typography, spacing, corner radii, motion, and icon sizes.
/// Both the panel (AppKit) and Settings/History (SwiftUI) read from here; avoid hardcoding font sizes or durations elsewhere.
/// Principles:
/// 1. Content first, chrome recedes: source text and results use content typography; controls and timings use secondary color.
/// 2. Accent color signals interactive state (pinned, success, selected, focused); errors and warnings use semantic colors. Brand and feature icons may use distinct identity colors.
/// 3. Motion only answers "did it register?" and "did the state change?".
enum Design {
    enum Onboarding {
        static let contentSize = NSSize(width: 480, height: 440)
        static let welcomeFont = Font.system(size: 22, weight: .semibold)
        static let appIconSize: CGFloat = 120
        static let eyeResponse: TimeInterval = 0.10
        static let headResponse: TimeInterval = 0.24
        static let rowIconWidth: CGFloat = 22
        static let primaryLabelWidth: CGFloat = 84
    }

    /// Metrics for the permission guide popover, anchored to the authorization pane's content column.
    enum PermissionGuide {
        static let width: CGFloat = 420
        static let sidebarWidth: CGFloat = 230
        static let minimumWidth: CGFloat = 240
        static let radius: CGFloat = 18
        static let cardRadius: CGFloat = 16
        static let cardInset: CGFloat = 6
        static let headerSpacing: CGFloat = 3
        static let contentSpacing: CGFloat = 6
        static let cardHeight: CGFloat = 48
        static let iconSize: CGFloat = 32
        static let headingFont = Font.system(size: 14)
        static let actionFont = Font.system(size: 15, weight: .semibold)
        static let closeFont = Font.system(size: 15, weight: .semibold)
        static let dragLabelFont = Font.system(size: 8, weight: .light)
        static let launchDuration: TimeInterval = 0.72
        static let wiggleAngle: Double = 12
        static let wiggleStep: TimeInterval = 0.22
    }

    // MARK: Typography

    enum Text {
        /// Extra line spacing within history body paragraphs, independent of inter-view layout spacing.
        static let bodyLineSpacing: CGFloat = 4

        /// Source text, card results, and history body.
        case content
        /// Card titles and language names: same size as label with one step lighter weight so source text and results stand out.
        case title
        /// Labels requiring tactile weight, such as keycaps.
        case label
        /// Standard settings row titles and values: 13pt regular, without inheriting label's semibold weight.
        case settingsRow
        /// Dictionary section headers, errors, and action hints.
        case body
        /// Dictionary auxiliary metadata: 12pt medium.
        case dictionaryAuxiliary
        /// Bilingual example sentence body: 14pt regular.
        case dictionaryExample
        /// Metadata captions such as latency, character count, examples, and tags.
        case note
        /// Tabular-aligned numbers: latency and character count.
        case noteDigits
        case bodyDigits
        /// Monospaced text such as diagnostic logs.
        case code
        /// Dictionary headword.
        case headword
        case sectionTitle
        case settingsPageTitle

        var size: CGFloat {
            switch self {
            case .content: return 16
            case .dictionaryExample: return 14
            case .settingsPageTitle: return 15
            case .title, .label, .settingsRow: return 13
            case .body, .bodyDigits, .dictionaryAuxiliary: return 12
            case .note, .noteDigits, .code: return 11
            case .headword: return 20
            case .sectionTitle: return 17
            }
        }

        var weight: NSFont.Weight {
            switch self {
            case .title, .dictionaryAuxiliary: return .medium
            case .label, .headword, .sectionTitle: return .semibold
            case .settingsPageTitle: return .bold
            case .bodyDigits: return .medium
            default: return .regular
            }
        }

        var nsFont: NSFont {
            switch self {
            case .noteDigits, .bodyDigits: return .monospacedDigitSystemFont(ofSize: size, weight: weight)
            case .code: return .monospacedSystemFont(ofSize: size, weight: weight)
            default: return .systemFont(ofSize: size, weight: weight)
            }
        }

        var font: Font {
            switch self {
            case .noteDigits, .bodyDigits: return .system(size: size, weight: swiftUIWeight).monospacedDigit()
            case .code: return .system(size: size, weight: swiftUIWeight, design: .monospaced)
            default: return .system(size: size, weight: swiftUIWeight)
            }
        }

        private var swiftUIWeight: Font.Weight {
            switch weight {
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            default: return .regular
            }
        }
    }

    // MARK: Layout: Rhythm Scale & Native Alignment

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        /// Horizontal inset inside containers: text in input fields, cards, and banners starts here along a shared leading edge.
        static let blockInset: CGFloat = m
        /// Trailing margin for icon buttons inside containers; buttons include ~5 pt internal padding, matching blockInset visually.
        static let iconButtonEdge: CGFloat = s
    }

    /// Alignment metrics matching native macOS forms (not snapped to the rhythm scale); shared by Settings and History.
    enum Layout {
        static let dividerWidth: CGFloat = 1
        static let pageInset: CGFloat = 20
        static let cardInset: CGFloat = 10
    }

    enum History {
        static let windowSize = NSSize(width: 860, height: 600)
        static let minimumSize = NSSize(width: 720, height: 500)
        static let sidebarMinimum: CGFloat = 220
        static let sidebarIdeal: CGFloat = 250
        static let sidebarMaximum: CGFloat = 320
    }

    /// Dictionary phonetic row: reserves clickable area for the native audio button and keeps alignment after wrapping.
    enum Dictionary {
        static let pronunciationButtonSize: CGFloat = 26
        static let pronunciationIndent = Space.xl
    }

    /// Settings layout; service pane outer margins align with the actual card edges of a native grouped Form.
    enum ShortcutRecorder {
        static let width:CGFloat=280
        static let keycapsHeight:CGFloat=34
        static let shakeDistance:CGFloat=6
    }

    enum Settings {
        static let toolbarKeyWidth: CGFloat = 100
        static let toolbarVisibilityWidth: CGFloat = 48

        /// Swatch icon size in the native theme menu.
        static let themeSwatchWidth: CGFloat = 24
        static let themeSwatchHeight: CGFloat = 16

        /// Compact native list row height matching macOS Preferred Languages.
        static let commonLanguageRowHeight: CGFloat = 24
        static let commonLanguageDescriptionHeight: CGFloat = 36
        static let commonLanguageActionsHeight: CGFloat = 28
        static let languageAdditionWidth: CGFloat = 516
        static let languageAdditionHeight: CGFloat = 400
        /// Matches margins, section spacing, and plain list text indentation of the system Add Preferred Language sheet.
        static let languageAdditionInset: CGFloat = 20
        static let languageAdditionHeaderSpacing: CGFloat = 8
        /// Symmetric vertical padding around action buttons.
        static let languageAdditionActionsSpacing: CGFloat = 14
        static let languageAdditionRowInset: CGFloat = 14
        static let languageAdditionButtonLabelWidth: CGFloat = 46
        static let languageSearchWidth: CGFloat = 160
        /// Localized language name column starts at 40% of list width.
        static let commonLanguageNativeColumnRatio: CGFloat = 0.4
        /// Horizontal row inset inside native grouped Form cards.
        static let commonLanguageCardInset = Layout.cardInset
        static let pageHorizontalInset = Layout.pageInset
        /// Unified toolbar already adds 8pt padding outside navigation items.
        static let toolbarTitleLeadingPadding = pageHorizontalInset - Space.s
        /// Preserves the 4pt top inset of grouped Form.
        static let formTopMarginAdjustment = -Space.l
        static let providerGridWidth: CGFloat = 320
        static let secondaryListWidth: CGFloat = 220
        static let secondaryRowHeight: CGFloat = 32
        static let listActionSize: CGFloat = 48
        static let controlHeight: CGFloat = 24
        /// Prompt editor has a fixed height equal to twice the original three-line default, scrolling internally.
        static let promptEditorHeight: CGFloat = 112
        static let segmentedThumbInset: CGFloat = 1
        static let actionRowHeight: CGFloat = 28
        static var rowFont: Font { Design.Text.settingsRow.font }
        static var groupFont: Font { Design.Text.label.font }
        static var groupNSFont: NSFont { Design.Text.label.nsFont }
        static var controlFont: NSFont { NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular)) }
        static var controlTextFont: Font { Font(controlFont) }
        static let logMinimumHeight: CGFloat = 240
        /// App icon display size in the About pane.
        static let aboutIconSize: CGFloat = 80
        /// Continuous rounded-square badge and inner glyph for sidebar feature icons.
        static let sidebarIconSize: CGFloat = 20
        static let sidebarIconRadius: CGFloat = 5.5
        static let sidebarIconBorderWidth: CGFloat = 0.5
        static let sidebarSymbolSize: CGFloat = 12
        /// Scale up narrower book and pin glyphs to match the visual weight of sibling symbols.
        static let sidebarLargeSymbolSize: CGFloat = 13
        static let sidebarIconShadowRadius: CGFloat = 1.2
        static let sidebarIconShadowOffset: CGFloat = 1
        static let navigationWidth: CGFloat = 180
        static let windowWidth: CGFloat = 820
        static let minimumHeight: CGFloat = 560
        static let maximumHeight: CGFloat = 900
        static let sliderWidth: CGFloat = 180
        static let valueWidth: CGFloat = 120
    }

    /// Visual metrics for the screenshot dimming mask and selection border.
    enum ScreenshotCapture {
        static let maskFill = NSColor.black.withAlphaComponent(0.5)
        static let borderWidth: CGFloat = 1
        static let cornerWidth: CGFloat = 3
        static let cornerMinimumSize: CGFloat = 20
        static let cornerOutside: CGFloat = 2
        static let cornerInside: CGFloat = 15
        /// Screenshot hints use a dark card with white keycaps.
        static let hintEdgeInset: CGFloat = 20
        static let hintHoverDistance: CGFloat = 12
        static let hintWidth: CGFloat = 208
        static let hintInset: CGFloat = 12
        static let hintRowHeight: CGFloat = 28
        static let hintTitleHeight: CGFloat = 20
        static let hintTitleSpacing: CGFloat = 8
        static let hintRadius: CGFloat = 12
        static let hintKeySize: CGFloat = 22
        static let hintKeyRadius: CGFloat = 5
        static let hintKeyGap: CGFloat = 12
        static let hintFill = NSColor(deviceRed: 0.10, green: 0.13, blue: 0.15, alpha: 0.88)
        static let hintBorder = NSColor.white.withAlphaComponent(0.18)
        static let hintText = NSColor.white
        static let hintKeyFill = NSColor(deviceWhite: 0.96, alpha: 1)
        static let hintKeyText = NSColor(deviceWhite: 0.12, alpha: 1)
        static let hintTitleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        static let hintBodyFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        static let hintKeyFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    }

    /// Loupe sampling and grid dimensions for region-selection preview only.
    enum ScreenshotMagnifier {
        static let size: CGFloat = 120
        static let distance: CGFloat = 10
        static let sizeAndDistance: CGFloat = 130
        static let crosshairAxis: CGFloat = 58
        static let crosshairGapStart: CGFloat = 55
        static let crosshairGapEnd: CGFloat = 60
        static let crosshairWidth: CGFloat = 5
        static let labelLight = NSColor.white
        static let labelDark = NSColor.black
        static let sampleSide: CGFloat = 12
        static let sampleRadius: CGFloat = 6
        static let gridStep: CGFloat = 5
        static let gridOffset: CGFloat = 0.5
        static let gridColor = NSColor.gray.withAlphaComponent(0.25)
        static let outerLineWidth: CGFloat = 2
        static let centerLineWidth: CGFloat = 1
        static let centerBoxSide: CGFloat = 6.5
        static let smallFont = NSFont.systemFont(ofSize: 8)
        static let outerInset: CGFloat = 1
        static let outerSide: CGFloat = 118
        static let centerOrigin: CGFloat = 54.5
    }

    /// Full-image preview shown outside the selection during scrolling capture.
    enum ScreenshotShadow {
        static let blur:CGFloat=12
        static let offset=NSSize(width:0,height:-3)
        static let inset:CGFloat=39
        static let defaultOpacity:Double=0.25
        static func color(rgb:Int,alpha:Double)->NSColor {NSColor(srgbRed:Double((rgb>>16)&255)/255,green:Double((rgb>>8)&255)/255,blue:Double(rgb&255)/255,alpha:alpha)}
    }
    enum ScreenshotSave { static let jpegBackground = NSColor.white }

    enum ScreenshotPin {
        /// Transparent alignment padding allowing Retina pinned screenshots to nudge by a single physical pixel within integer window coordinates.
        static let drawingInset: CGFloat = 1
        static let menuHintPosition: CGFloat = 210
        static let menuFont = NSFont.menuFont(ofSize: 13)
        static let closeSize: CGFloat = 20
        static let closeSymbolSize: CGFloat = 12
        static let closeInset: CGFloat = 4
        static let textWidth: CGFloat = 480
        static let textInset: CGFloat = 20
    }

    enum ScreenshotScroll {
        static let previewWidth: CGFloat = 200
        static let previewHeight: CGFloat = 640
        /// Move inside the selection when available container height is insufficient to avoid squashing into a narrow horizontal strip.
        static let minimumPreviewSpace: CGFloat = 120
        static let minimumPreviewWidth: CGFloat = 160
        /// Tracked capture viewport indicator; drawn on the preview only, never baked into the final image.
        static let viewportLineWidth: CGFloat = 1
        static let viewportCornerWidth: CGFloat = 2
        static let viewportCornerLength: CGFloat = 8
        /// Reserves top and bottom toolbar clearance for centered editing without downscaling exported pixels.
        static let editorInset: CGFloat = 96
    }

    /// Local OCR result window: minimum usable dimensions for the language bar, source image comparison, and text editor.
    enum OCR {
        static let windowSize = NSSize(width: 760, height: 560)
        static let comparisonSize = NSSize(width: 1040, height: 680)
        // Both views share the same minimum window size to fit both panes and margins without resizing the window frame on switch.
        static let minimumSize = NSSize(width: minimumPanelWidth * 2 + Design.Space.m + Design.Space.l * 2, height: 360)
        /// Shared lower bound for the image and text panes; accommodates the bottom icons and language button in the text pane.
        static let minimumPanelWidth: CGFloat = 320
        static let minimumZoom: CGFloat = 0.05
        static let maximumZoom: CGFloat = 16
        static let wheelZoomSensitivity: CGFloat = 0.04
        static let preciseZoomSensitivity: CGFloat = 0.005
        static let languageHeight: CGFloat = 32
        static let actionSize: CGFloat = 28
        static let topBarHeight: CGFloat = 32
        static let topPanelGap: CGFloat = 4
        static let bottomActionsInset: CGFloat = 8
        static let languageHorizontalInset: CGFloat = 12
        static let minimumTextHeight: CGFloat = 160
    }

    enum ScreenshotEditor {
        /// Shared appearance for the main screenshot toolbar and active tool options bar.
        static let toolbarButtonSize: CGFloat = 28
        static let toolbarSymbolSize: CGFloat = 17
        static let toolbarButtonRadius: CGFloat = 8
        static let toolbarRadius: CGFloat = 14
        static let toolbarItemSpacing: CGFloat = 4
        static let toolbarBarInset: CGFloat = 6
        static let toolbarOptionsSpacing: CGFloat = 12
        static let toolbarControlHeight: CGFloat = 24
        /// Secondary options bar has a fixed height; option count only affects width.
        static let toolbarOptionsHeight: CGFloat = 40
        /// Compact width/height and aspect-ratio badge above the selection's top-left corner.
        static let sizeToolbarHeight = toolbarOptionsHeight * 0.6
        static let sizeControlHeight: CGFloat = 16
        static let sizeFieldWidth: CGFloat = 48
        static let sizeRatioMinimumWidth: CGFloat = 14
        /// Compensates for invisible trailing padding on the native menu chevron to balance visible horizontal margins.
        static let sizeRatioTrailingInset: CGFloat = 5
        static let sizeFieldRadius: CGFloat = 4
        static let sizeSymbolSize: CGFloat = 12
        static let sizeToolbarRadius: CGFloat = 7
        static let sizeSliderWidth: CGFloat = 64
        static let sizeDividerHeight: CGFloat = 12
        static let annotationNumberFontRatio: CGFloat = 0.8
        static let annotationMarkerGap: CGFloat = 12
        static let highlighterOpacity: CGFloat = 0.35
        static let highlighterRadius: CGFloat = 3
        static let highlighterTextPadding: CGFloat = 2
        /// Hollow highlighter brush cursor: white outer ring, black inner ring, transparent center.
        static let highlighterCursorWidth: CGFloat = 10
        static let highlighterCursorMinimumHeight: CGFloat = 14
        static let highlighterCursorBlackWidth: CGFloat = 2
        static let highlighterCursorWhiteWidth: CGFloat = 1
        static let toolbarSliderWidth: CGFloat = 84
        static let toolbarOptionSegmentWidth: CGFloat = 28
        static let toolbarGlyphLineWidth: CGFloat = 1.5
        static let toolbarSwatchSize: CGFloat = 18
        static let toolbarTrackHeight: CGFloat = 3
        static let valueBubbleHorizontalInset: CGFloat = 12
        static let valueBubbleVerticalInset: CGFloat = 10
        static let toolbarDividerWidth: CGFloat = 1
        static let toolbarDividerHeight: CGFloat = 24
        static let annotationLineWidth: CGFloat = 2
        static let annotationDotRatio: CGFloat = 0.22
        static let annotationNumberRatio: CGFloat = 0.525
        static let annotationTextGap: CGFloat = 12
        static let defaultFocusOpacity: CGFloat = 0.5
        static let defaultFillOpacity: CGFloat = 0.25
        static let defaultCornerRadius: CGFloat = 8
        static let maximumCornerRadius: CGFloat = 80
        static let handleSize: CGFloat = 8
        static let textSize: CGFloat = 18
        /// Default red color for image annotations.
        static let defaultStrokeColor = NSColor.red
        static func restoredColor(_ rgba: [Double]) -> NSColor {
            guard rgba.count == 4 else { return defaultStrokeColor }
            return NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        }
        static func font(size: CGFloat) -> NSFont { .systemFont(ofSize: size) }
        static func serialFont(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size) }
        /// Original lower opacity bound from CustomView scrollWheel:.
        static let minimumPinOpacity: CGFloat = 0.1
        /// Original DefaultPreferences sizeOfPinFillet=8.
        static let handleFill = NSColor.white
        static let highlightFill = NSColor.black
    }

    /// Reusable sliding segmented control: content stays fixed while only the selection capsule moves.
    enum Segmented {
        /// Two explicit size tiers: 24pt to align with native controls in Settings rows, and 28pt for the screenshot toolbar.
        enum Size {
            case compact, regular
            var height: CGFloat { self == .compact ? Settings.controlHeight : Segmented.height }
            var horizontalInset: CGFloat { self == .compact ? compactHorizontalInset : Segmented.horizontalInset }
            var radius: CGFloat { self == .compact ? compactRadius : Segmented.radius }
        }
        static let compactHorizontalInset: CGFloat = 8
        static let compactRadius: CGFloat = 7
        static let height: CGFloat = 28
        static let horizontalInset: CGFloat = 10
        static let thumbInset: CGFloat = 2
        static let radius: CGFloat = 9
        static let contentGap: CGFloat = 5
        static let iconSize: CGFloat = 17
        /// Background/border styling for the Aa text-style preview; glyph always uses the standard SF textformat symbol.
        static let textStyleIconSize: CGFloat = 14
        /// Each text-style segment is 38pt wide, adding 2pt of extra padding on each side over default content width.
        static let textStyleSegmentWidth: CGFloat = 38
        static let symbolBadgeInset: CGFloat = 3
        static let symbolBadgeHeight: CGFloat = 17
        static let symbolBadgeRadius: CGFloat = 4
        static let symbolBadgeLineWidth: CGFloat = 1.5
        static let font = Text.settingsRow.nsFont
    }
    enum AnnotationEditor {
        static let inset: CGFloat = 8
        static let radius: CGFloat = 10
        static let maximumAutoWidth: CGFloat = 400
        static let textMeasurementPadding: CGFloat = 2
        static let defaultWidth: CGFloat = 40
        static let minimumWidth: CGFloat = 40
        static let minimumHeight: CGFloat = 28
        static let emptyAspectRatio: CGFloat = 1.25
        static let borderWidth: CGFloat = 1.5
        static let textBorderInset: CGFloat = 3
        static let handleWidth: CGFloat = 3
        static let handleHeight: CGFloat = 12
    }

    // MARK: Corner Radius

    enum Radius {
        /// Input fields, language bar, and cards.
        static let block: CGFloat = 8
        /// Small controls and keycaps.
        static let control: CGFloat = 5
        /// Corner radius ratio for service brand icons relative to side length, matching macOS app icons.
        static let brandTileRatio: CGFloat = 0.225
    }

    /// In-place status capsule; fixed height, width adapts to the status text.
    enum ReplacementHUD {
        static let height: CGFloat = 30
        static let resultHold: TimeInterval = 1.5
        static let maximumWidth: CGFloat = 360
        static let orbSize: CGFloat = 20
        static let frameInterval: TimeInterval = 1.0 / 30
        static let shimmerDuration: TimeInterval = 1
        static let shimmerSpread: CGFloat = 0.24
        static let shimmerConcentration: CGFloat = 1.5
        static let cornerRadius: CGFloat = height / 2
        static let borderWidth: CGFloat = 0.5
    }

    // MARK: Motion

    enum Motion {
        /// Icon swaps, crossfades, and press feedback.
        static let fast: TimeInterval = 0.15
        /// Expand/collapse, height changes, and rotation.
        static let standard: TimeInterval = 0.24
        /// Hold duration for success feedback.
        static let hold: TimeInterval = 1.2
        /// Delay before auto-closing the popover after recording a shortcut.
        static let settle: TimeInterval = 0.6
        /// Duration for tracking height as streamed text grows (frame-by-frame tracking, not a transition; higher values lag).
        static let follow: TimeInterval = 0.10
        /// Frame interval for speaker wave animation (playback cadence, not a transition).
        static let speakerFrame: TimeInterval = 0.35

        static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    }

    // MARK: Icons

    enum Icon {
        /// Tool and card action buttons.
        static let action: CGFloat = 16
        /// Fixed hit target for card actions to preserve layout during icon or feedback changes.
        static let cardActionSize: CGFloat = 26
        /// Small icons such as disclosure chevrons.
        static let small: CGFloat = 11
        /// Up/down chevrons for pop-up menus.
        static let tiny: CGFloat = 9
        /// Empty-state illustration.
        static let hero: CGFloat = 30
        /// Service brand icon (rounded square).
        static let brand: CGFloat = 20

        /// Custom symbols bundled with Seven (`Resources/Symbols.xcassets`, compiled into the app by actool during packaging).
        /// Swap languages: right-over-left harpoons (⇌).
        static let swapLanguages = "seven.swap"

        /// Fallback system symbols used when custom symbols are unavailable (e.g. running tests without packaging).
        static let screenshotFocus = "squareshape.on.pattern.diagonalline"
        /// Mosaic uses the standard black-and-white checkerboard symbol.
        static let screenshotMosaic = "checkerboard.rectangle"
        /// SVG template asset for the six-dot drag handle.
        static let screenshotDrag = "ScreenshotDragHandle"
        private static let customFallbacks = [swapLanguages: "arrow.left.arrow.right", screenshotFocus: "square.on.square"]

        /// Resolves a symbol by name: checks system SF Symbols first, then Seven's bundled custom symbols, and finally falls back to a system symbol.
        static func symbol(_ name: String, description: String? = nil, tint: NSColor? = nil) -> NSImage? {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
                ?? NSImage(symbolName: name, bundle: .main, variableValue: 0)
                ?? customFallbacks[name].flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: description) }
            guard let tint, let colored = image?.withSymbolConfiguration(.init(paletteColors: [tint])) else { return image }
            // Native segmented controls re-tint template images with the system color; preserve the configured symbol palette.
            colored.isTemplate = false
            return colored
        }
    }

    enum Palette {
        /// Third-party service brand colors (hex RGB) for service icons only; do not use for Seven's own UI.
        static func brand(_ rgb: UInt32) -> NSColor { ThemePalette.rgb(rgb) }
    }

    // MARK: Opacity

    enum Opacity {
        /// Disabled controls, inactive states, and placeholder content.
        static let disabled: CGFloat = 0.4
    }

    // MARK: Keycaps

    enum Keycap {
        static let radius = Radius.control
        static let spacing = Space.xs
        static let strokeWidth: CGFloat = 1
    }
}
