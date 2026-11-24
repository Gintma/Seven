import SwiftUI

struct OnboardingWelcomeView: View {
    let title: String
    let cue: MascotCue?
    let locate: (CGPoint) -> Void

    var body: some View {
        VStack(spacing: Design.Space.s) {
            OnboardingMascot(cue: cue)
                .frame(width: Design.Onboarding.appIconSize, height: Design.Onboarding.appIconSize)
                .onGeometryChange(for: CGPoint.self) { proxy in
                    let frame = proxy.frame(in: .global)
                    return CGPoint(x: frame.midX, y: frame.midY)
                } action: { locate($0) }
                .accessibilityHidden(true)
            Text(title)
                .font(Design.Onboarding.welcomeFont)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity)
    }
}
