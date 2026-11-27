import SwiftUI

struct SettingsSidebarIcon: View {
    @Environment(\.theme) private var theme
    private let symbol: String
    private let tint: Color?
    private let darkTint: Color?
    private let symbolSize: CGFloat

    init(
        _ symbol: String,
        tint: Color? = nil,
        darkTint: Color? = nil,
        symbolSize: CGFloat = Design.Settings.sidebarSymbolSize
    ) {
        self.symbol = symbol
        self.tint = tint
        self.darkTint = darkTint
        self.symbolSize = symbolSize
    }

    var body: some View {
        let isDark = theme.variant == .dark
        let plate = RoundedRectangle(cornerRadius: Design.Settings.sidebarIconRadius, style: .continuous)
        let appearanceTint = isDark ? darkTint ?? tint : tint
        let isGray = appearanceTint == nil
        let gray = isDark ? 0.60 : 0.62
        let fill = appearanceTint ?? Color(red: gray, green: gray, blue: gray + 0.02)
        let topHighlight = isGray ? 0.15 : (isDark ? 0.20 : 0.25)
        let bottomShade = isGray ? 0.10 : (isDark ? 0.24 : 0.19)
        let upperEdge = isGray ? 0.24 : (isDark ? 0.26 : 0.37)
        let lowerEdge = isGray ? 0.08 : (isDark ? 0.24 : 0.12)
        let shadow = isGray ? 0.15 : (isDark ? 0.43 : 0.23)
        let shading = LinearGradient(
            stops: [
                .init(color: .white.opacity(topHighlight), location: 0),
                .init(color: .clear, location: 0.46),
                .init(color: .black.opacity(bottomShade), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        let edge = LinearGradient(
            stops: [
                .init(color: .white.opacity(upperEdge), location: 0),
                .init(color: .clear, location: 0.58),
                .init(color: .black.opacity(lowerEdge), location: 1),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        Image(systemName: symbol)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: symbolSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Design.Settings.sidebarIconSize, height: Design.Settings.sidebarIconSize)
            .background {
                plate
                    .fill(fill)
                    .shadow(color: .black.opacity(shadow),
                            radius: Design.Settings.sidebarIconShadowRadius,
                            y: Design.Settings.sidebarIconShadowOffset)
                    .overlay {
                        plate.fill(shading)
                            .strokeBorder(edge, lineWidth: Design.Settings.sidebarIconBorderWidth)
                    }
            }
            .accessibilityHidden(true)
    }
}
