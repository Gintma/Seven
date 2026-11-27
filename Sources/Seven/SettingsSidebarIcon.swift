import SwiftUI

struct SettingsSidebarIcon: View {
    @Environment(\.theme) private var theme
    private let symbol: String
    private let tint: Color?
    private let symbolSize: CGFloat

    init(_ symbol: String, tint: Color? = nil, symbolSize: CGFloat = Design.Settings.sidebarSymbolSize) {
        self.symbol = symbol
        self.tint = tint
        self.symbolSize = symbolSize
    }

    var body: some View {
        let isDark = theme.variant == .dark
        let plate = RoundedRectangle(cornerRadius: Design.Settings.sidebarIconRadius, style: .continuous)
        let fill = tint ?? Color(white: isDark ? 0.36 : 0.51)
        let shading = LinearGradient(
            stops: [
                .init(color: .white.opacity(isDark ? 0.20 : 0.25), location: 0),
                .init(color: .clear, location: 0.46),
                .init(color: .black.opacity(isDark ? 0.24 : 0.19), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        let edge = LinearGradient(
            stops: [
                .init(color: .white.opacity(isDark ? 0.26 : 0.37), location: 0),
                .init(color: .clear, location: 0.58),
                .init(color: .black.opacity(isDark ? 0.24 : 0.12), location: 1),
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
                    .shadow(color: .black.opacity(isDark ? 0.43 : 0.23),
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
