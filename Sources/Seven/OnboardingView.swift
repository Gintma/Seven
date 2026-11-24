import AppKit
import CoreGraphics
import SwiftUI

struct OnboardingView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @State private var accessibilityGranted = SelectionReader.isAccessibilityTrusted
    @State private var screenRecordingGranted = CGPreflightScreenCaptureAccess()

    let flow: OnboardingFlow
    let authorize: (PermissionGuide.Permission) -> Void
    let start: () -> Void
    @State private var cue: MascotCue?
    @State private var mascotCenter = CGPoint.zero
    @State private var rowCenters: [OnboardingFlow.Reaction: CGPoint] = [:]
    @State private var isKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingWelcomeView(title: L10n.text("onboarding.welcome"), cue: cue) { mascotCenter = $0 }
            Spacer(minLength: Design.Space.m)
            settingsCard
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Design.Space.m)
            startButton.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Design.Space.xl)
        .padding(.vertical, Design.Space.l)
        .tint(theme.isSystem ? nil : theme.swiftUI.accentFill)
        .themeDetailSurface()
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.windowController is OnboardingWindowController else { return }
            isKey = true
            launchAtLogin.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard (notification.object as? NSWindow)?.windowController is OnboardingWindowController else { return }
            isKey = false
            cue = nil
        }
        .onAppear {
            isKey = NSApp.keyWindow?.windowController is OnboardingWindowController
            launchAtLogin.refresh()
        }
        .task(id: isKey) {
            guard isKey else { return }
            while !Task.isCancelled {
                refreshPermissions()
                if launchAtLogin.state == .requiresApproval { launchAtLogin.refresh() }
                if rowCenters.count == 2, mascotCenter != .zero,
                   let reaction = flow.nextReaction(accessibility: accessibilityGranted,
                    screenRecording: screenRecordingGranted, login: launchAtLogin.state) {
                    let target = rowCenters[reaction] ?? mascotCenter
                    let dx = target.x - mascotCenter.x
                    let dy = mascotCenter.y - target.y
                    let length = max(1, hypot(dx, dy))
                    cue = MascotCue(reaction: reaction, direction: CGPoint(x: dx / length, y: dy / length))
                    do { try await Task.sleep(for: .milliseconds(850)) } catch { return }
                    cue = nil
                }
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            }
        }
    }

    private var settingsCard: some View {
        let outline = RoundedRectangle(cornerRadius: Design.Radius.block)
        return VStack(spacing: 0) {
            permissionRow(.accessibility, reaction: .accessibility, icon: "accessibility",
                          explanation: L10n.text("onboarding.accessibility"), granted: accessibilityGranted)
            rowDivider
            permissionRow(.screenRecording, reaction: .screenRecording, icon: "macwindow",
                          explanation: L10n.text("onboarding.screenRecording"), granted: screenRecordingGranted)
            rowDivider
            login
                .padding(.vertical, Design.Space.s)
        }
        .background(ThemeStyle.permissionCardFill, in: outline)
        .overlay { outline.strokeBorder(ThemeStyle.permissionCardStroke).allowsHitTesting(false) }
    }

    private var rowDivider: some View {
        ThemedDivider()
            .padding(.leading, Design.Space.m + Design.Onboarding.rowIconWidth + Design.Space.m)
            .padding(.trailing, Design.Space.m)
    }

    private func permissionRow(_ permission: PermissionGuide.Permission, reaction: OnboardingFlow.Reaction, icon: String, explanation: String,
                               granted: Bool) -> some View {
        HStack(spacing: Design.Space.m) {
            featureIcon(icon)
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                Text(permission.title).font(Design.Text.label.font)
                SettingsNote(text: explanation, multiline: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if granted {
                    Label {
                        Text(L10n.text("granted2")).foregroundStyle(ThemeStyle.ink)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.swiftUI.permissionGranted)
                    }
                    .font(Design.Settings.rowFont)
                    .accessibilityLabel(L10n.format("granted", permission.title))
                    .fixedSize()
                } else {
                    Button(L10n.text("grantAccess")) {
                        flow.awaitSuccess(reaction)
                        authorize(permission)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(L10n.format("onboarding.authorize", permission.title))
                    .fixedSize()
                }
            }
            .onGeometryChange(for: CGPoint.self) { proxy in
                let frame = proxy.frame(in: .global)
                return CGPoint(x: frame.midX, y: frame.midY)
            } action: { rowCenters[reaction] = $0 }
        }
        .frame(minHeight: Design.Settings.controlHeight)
        .padding(.vertical, Design.Space.s)
        .padding(.horizontal, Design.Space.m)
    }

    private var login: some View {
        HStack(spacing: Design.Space.m) {
            featureIcon("power")
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                SettingsToggleRow(L10n.text("launchAtLogin"), isOn: Binding(
                    get: { launchAtLogin.enabled }, set: { enabled in
                        launchAtLogin.setEnabled(enabled)
                        if enabled && launchAtLogin.enabled { flow.awaitSuccess(.login) }
                        else { flow.forget(.login) }
                    }
                ))
                if let message = launchAtLogin.message {
                    HStack(spacing: Design.Space.s) {
                        SettingsNote(text: message, multiline: true)
                            .fixedSize(horizontal: false, vertical: true)
                        if launchAtLogin.state == .requiresApproval {
                            Button(L10n.text("openLoginItemsSettings")) { launchAtLogin.openSystemSettings() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .fixedSize()
                        }
                    }
                }
            }
        }
        .environment(\.settingsDetailMode, true)
        .padding(.horizontal, Design.Space.m)
    }

    private func featureIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(Design.Text.sectionTitle.font)
            .foregroundStyle(ThemeStyle.inkSecondary)
            .frame(width: Design.Onboarding.rowIconWidth)
            .accessibilityHidden(true)
    }

    private var startButton: some View {
        Button(action: start) {
            HStack(spacing: Design.Space.s) {
                Text(L10n.text("onboarding.start"))
                Image(systemName: "arrow.right").accessibilityHidden(true)
            }
            .frame(minWidth: Design.Onboarding.primaryLabelWidth)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    private func refreshPermissions() {
        let accessibility = SelectionReader.isAccessibilityTrusted
        let screen = CGPreflightScreenCaptureAccess()
        if accessibility && !accessibilityGranted { flow.awaitSuccess(.accessibility) }
        if screen && !screenRecordingGranted { flow.awaitSuccess(.screenRecording) }
        accessibilityGranted = accessibility
        screenRecordingGranted = screen
    }
}
