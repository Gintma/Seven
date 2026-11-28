import SwiftUI
import AppKit

/// Service icons are unified as equal-sized rounded squares, with monochrome glyphs rendered in white on a brand-colored background.
/// Official icons that are already full squares (Youdao, Apple Translate) are clipped to the same corner radius; white-background tiles get a subtle border.
/// Icon assets live in Resources/BrandIcons.
struct BrandTile: Equatable {
    enum Glyph: Equatable {
        /// Monochrome vector graphic tinted white and centered, with `scale` as a fraction of the tile side length.
        case monochrome(String, scale: CGFloat)
        /// Full-color graphic drawn centered as-is.
        case color(String, scale: CGFloat)
        /// Official icon that is already a full square, filled edge-to-edge and clipped to rounded corners.
        case fullBleed(String)
        /// System symbol rendered in white.
        case symbol(String, scale: CGFloat)
    }

    let background: NSColor
    let glyph: Glyph
    /// White-background tiles need a subtle border to remain legible against light backgrounds.
    let outlined: Bool

    init(_ background: NSColor, _ glyph: Glyph, outlined: Bool = false) {
        self.background = background
        self.glyph = glyph
        self.outlined = outlined
    }
}

enum ServiceBrandIconCatalog {
    static func tile(provider: TranslationProviderID?, serviceName: String) -> BrandTile {
        switch provider {
        case .youdao: return youdao
        case .google: return googleTranslate
        case .appleTranslation: return appleTranslate
        case .ecdict: return dictionary
        default: return tile(named: serviceName)
        }
    }

    /// Matches custom services against common brands by name; falls back to a generic icon on a neutral gray background when unrecognized.
    static func tile(named serviceName: String) -> BrandTile {
        let name = serviceName.lowercased()
        let brands: [([String], BrandTile)] = [
            (["openai", "chatgpt", "gpt"], openai),
            (["claude", "anthropic"], claude),
            (["deepseek"], deepseek),
            (["gemini"], gemini),
            (["minimax"], minimax),
            (["qwen", "通义", "千问", "dashscope"], qwen),
            (["doubao", "豆包", "volcengine", "火山"], doubao),
            (["kimi", "moonshot", "月之暗面"], kimi),
            (["deepl"], deepl),
            (["zhipu", "智谱", "glm", "bigmodel", "z.ai"], zhipu),
            (["openrouter"], openrouter),
            (["youdao", "有道"], youdao),
            (["google"], googleTranslate),
            (["apple"], appleTranslate),
            (["词典", "dict"], dictionary)
        ]
        return brands.first { keys, _ in keys.contains { name.contains($0) } }?.1 ?? generic
    }

    static func speechTile(for engine: SpeechEngineID) -> BrandTile {
        switch engine {
        case .system: return systemSpeech
        case .youdao: return youdao
        case .baidu: return baidu
        case .google: return googleTranslate
        }
    }

    static let baidu = BrandTile(Design.Palette.brand(0x2932E1), .monochrome("baidu.svg", scale: 0.75))
    static let systemSpeech = BrandTile(generic.background, .symbol("speaker.wave.2.fill", scale: 0.7))

    static let zhipu = BrandTile(Design.Palette.brand(0x3859FF), .monochrome("zhipu.svg", scale: 0.75))
    static let deepseek = BrandTile(Design.Palette.brand(0x4D6BFE), .monochrome("deepseek.svg", scale: 0.75))
    static let openrouter = BrandTile(Design.Palette.brand(0x000000), .monochrome("openrouter.svg", scale: 0.72))
    static let openai = BrandTile(Design.Palette.brand(0x000000), .monochrome("openai.svg", scale: 0.72))
    static let claude = BrandTile(Design.Palette.brand(0xD97757), .monochrome("claude.svg", scale: 0.72))
    static let minimax = BrandTile(Design.Palette.brand(0xF23F5D), .monochrome("minimax.svg", scale: 0.72))
    static let qwen = BrandTile(Design.Palette.brand(0x082DFF), .monochrome("qwen.svg", scale: 0.62))
    static let kimi = BrandTile(Design.Palette.brand(0x000000), .monochrome("kimi.svg", scale: 0.62))
    static let deepl = BrandTile(Design.Palette.brand(0x0F2B46), .monochrome("deepl.svg", scale: 0.7))
    static let gemini = BrandTile(Design.Palette.brand(0xFFFFFF), .color("gemini.png", scale: 0.72), outlined: true)
    static let doubao = BrandTile(Design.Palette.brand(0xFFFFFF), .color("doubao.png", scale: 0.75), outlined: true)
    static let googleTranslate = BrandTile(
        Design.Palette.brand(0xFFFFFF), .color("google-translate.svg", scale: 0.8), outlined: true
    )
    static let youdao = BrandTile(Design.Palette.brand(0xFFFFFF), .fullBleed("youdao.png"))
    static let appleTranslate = BrandTile(Design.Palette.brand(0xFFFFFF), .fullBleed("apple-translate.png"))
    /// English-Chinese dictionary (ECDICT) has no official logo: neutral dark gray background with a white dictionary symbol.
    static let dictionary = BrandTile(
        Design.Palette.brand(0x3A3A3C), .symbol("character.book.closed.fill", scale: 0.62)
    )
    /// Custom service whose brand is not recognized.
    static let generic = BrandTile(Design.Palette.brand(0x8E8E93), .symbol("sparkles", scale: 0.6))
}

/// Renders a `BrandTile` into an icon of the given side length; shared by the floating panel (AppKit) and settings view (SwiftUI).
@MainActor
enum BrandIconRenderer {
    private static var resourceCache: [String: NSImage] = [:]

    static func image(provider: TranslationProviderID?, serviceName: String, size: CGFloat) -> NSImage {
        image(for: ServiceBrandIconCatalog.tile(provider: provider, serviceName: serviceName), size: size)
    }

    static func image(for requested: BrandTile, size: CGFloat) -> NSImage {
        // Fall back to the generic icon when resources are missing (e.g., running tests without bundling) so the slot is never blank.
        let tile = hasResource(requested.glyph) ? requested : ServiceBrandIconCatalog.generic
        let tinted = whiteGlyph(for: tile.glyph)
        let colorGlyph = colorImage(for: tile.glyph)
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let radius = rect.width * Design.Radius.brandTileRatio
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            tile.background.setFill()
            rect.fill()
            switch tile.glyph {
            case .fullBleed:
                colorGlyph?.draw(in: rect)
            case .color(_, let scale):
                colorGlyph?.draw(in: centered(in: rect, scale: scale))
            case .monochrome(_, let scale), .symbol(_, let scale):
                tinted?.draw(in: centered(in: rect, scale: scale))
            }
            NSGraphicsContext.restoreGraphicsState()
            if tile.outlined {
                let inset = Design.Keycap.strokeWidth / 2
                let outline = NSBezierPath(
                    roundedRect: rect.insetBy(dx: inset, dy: inset),
                    xRadius: radius - inset, yRadius: radius - inset
                )
                outline.lineWidth = Design.Keycap.strokeWidth
                ThemePalette.system.brandTileStroke.setStroke()
                outline.stroke()
            }
            return true
        }
    }

    private static func hasResource(_ glyph: BrandTile.Glyph) -> Bool {
        switch glyph {
        case .monochrome(let name, _), .color(let name, _), .fullBleed(let name): return resource(name) != nil
        case .symbol: return true
        }
    }

    private static func colorImage(for glyph: BrandTile.Glyph) -> NSImage? {
        switch glyph {
        case .color(let name, _), .fullBleed(let name): return resource(name)
        case .monochrome, .symbol: return nil
        }
    }

    /// Tint monochrome graphics and system symbols white separately first so tinting does not affect the tile background.
    private static func whiteGlyph(for glyph: BrandTile.Glyph) -> NSImage? {
        let source: NSImage?
        switch glyph {
        case .monochrome(let name, _):
            source = resource(name)
        case .symbol(let name, _):
            source = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: Design.Icon.hero, weight: .medium))
        case .color, .fullBleed:
            return nil
        }
        guard let source else { return nil }
        return NSImage(size: NSSize(width: Design.Icon.hero, height: Design.Icon.hero), flipped: false) { rect in
            source.draw(in: aspectFit(source.size, in: rect))
            Design.Palette.brand(0xFFFFFF).set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private static func resource(_ fileName: String) -> NSImage? {
        if let cached = resourceCache[fileName] { return cached }
        let file = URL(filePath: fileName, directoryHint: .checkFileSystem)
        guard let url = Bundle.main.url(
            forResource: file.deletingPathExtension().lastPathComponent,
            withExtension: file.pathExtension,
            subdirectory: "BrandIcons"
        ), let image = NSImage(contentsOf: url) else { return nil }
        resourceCache[fileName] = image
        return image
    }

    private static func centered(in rect: NSRect, scale: CGFloat) -> NSRect {
        let side = rect.width * scale
        return NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    }

    /// SVGs declare their size in 1em (loaded as 1x1 by NSImage); scale proportionally to fill the target rect.
    private static func aspectFit(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let factor = min(rect.width / size.width, rect.height / size.height)
        let fitted = NSSize(width: size.width * factor, height: size.height * factor)
        return NSRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }
}

struct ServiceBrandIcon: View {
    let provider: TranslationProviderID?
    let serviceName: String
    let active: Bool
    var size: CGFloat = Design.Icon.brand

    var body: some View {
        Image(nsImage: BrandIconRenderer.image(provider: provider, serviceName: serviceName, size: size))
            .resizable()
            .frame(width: size, height: size)
            .saturation(active ? 1 : 0)
            .opacity(active ? 1 : Design.Opacity.disabled)
            .accessibilityHidden(true)
    }
}
