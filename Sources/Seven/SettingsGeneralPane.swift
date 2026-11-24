import SwiftUI

extension SettingsView {
    var generalPane: some View {
        SettingsForm {
            SettingsGroup {
                SettingsPickerRow(L10n.text("interfaceLanguage"), selection: Binding(
                    get: { interfaceLanguage.selection },
                    set: { interfaceLanguage.select($0) }
                )) {
                    ForEach(InterfaceLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                SettingsSegmentedRow(title: L10n.text("appearance"), selection: Binding(
                    get: { themeManager.appearanceMode },
                    set: { themeManager.selectAppearanceMode($0) }
                ), options: AppearanceMode.allCases.map { ($0, $0.title) })
                SettingsThemePickerRow(variant: .light, manager: themeManager)
                SettingsThemePickerRow(variant: .dark, manager: themeManager)
                SettingsToggleRow(L10n.text("launchAtLogin"), isOn: Binding(
                    get: { launchAtLogin.enabled }, set: { launchAtLogin.setEnabled($0) }
                ), explanation: launchAtLogin.message)
                if launchAtLogin.state == .requiresApproval {
                    SettingsButtonRow(L10n.text("loginItems")) { Button(L10n.text("openLoginItemsSettings")) { launchAtLogin.openSystemSettings() } }
                }
            }
            SettingsGroup(L10n.text("permissions")) {
                SettingsPermissionRow(title: L10n.text("accessibility"), granted: SelectionReader.isAccessibilityTrusted) {
                    PermissionGuide.shared.authorize(.accessibility)
                }
                SettingsPermissionRow(title: L10n.text("screenRecording"), granted: screenCaptureTrusted) {
                    PermissionGuide.shared.authorize(.screenRecording)
                }
            }
        }
    }
}
