import AppKit

/// sRGB 值，用于纯计算。构建原生颜色前保留导出值的透明度。
struct ThemeColor: Equatable, ExpressibleByIntegerLiteral {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double

    init(rgb: UInt32, opacity: Double = 1) {
        red = Double((rgb >> 16) & 255) / 255
        green = Double((rgb >> 8) & 255) / 255
        blue = Double(rgb & 255) / 255
        self.opacity = opacity
    }

    init(integerLiteral value: UInt32) { self.init(rgb: value) }

    init?(nsColor: NSColor) {
        guard let color = nsColor.usingColorSpace(.sRGB) else { return nil }
        self.init(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent, opacity: color.alphaComponent)
    }

    private init(red: Double, green: Double, blue: Double, opacity: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: opacity) }

    func mixed(with other: Self, fraction: Double) -> Self {
        let inverse = 1 - fraction
        return Self(red: red * inverse + other.red * fraction,
                    green: green * inverse + other.green * fraction,
                    blue: blue * inverse + other.blue * fraction,
                    opacity: opacity * inverse + other.opacity * fraction)
    }

    func withOpacity(_ opacity: Double) -> Self {
        Self(red: red, green: green, blue: blue, opacity: opacity)
    }

    func over(_ background: Self) -> Self {
        background.mixed(with: withOpacity(1), fraction: opacity)
    }

    private var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrast(against background: Self) -> Double {
        let foreground = over(background).luminance
        let background = background.luminance
        return (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
    }
}
