import SwiftUI

extension SettingsView {
    var ocrPane:some View {
        SettingsForm {
            SettingsGroup(L10n.text("recognition")) {
                SettingsPickerRow(L10n.text("ocrLanguage"), selection: $ocrRecognitionLanguage) {
                    Text(L10n.text("detectAutomatically2")).tag(LanguageCatalog.automatic)
                    ForEach(OCRRecognitionLanguages.supported(), id: \.self) { code in
                        Text(OCRRecognitionLanguages.name(code)).tag(code)
                    }
                }
                SettingsToggleRow(L10n.text("smartSelection"), isOn: $ocrSmartSelectionEnabled, explanation: L10n.text("detectInterfaceElementsAutomatically"))
            }
            SettingsGroup(L10n.text("keyboardShortcuts")) {
                ForEach(OCRMode.allCases){mode in
                    SettingsShortcutRow(title:mode.title,manager:ocrShortcuts.manager(mode),allManagers:allHotKeyManagers, feedback: pageFeedback,
                        isRecording:Binding(get:{recordingOCRMode==mode},set:{recordingOCRMode=$0 ? mode:nil}),explanation:mode.explanation)
                }
                SettingsShortcutRow(title: L10n.text("clipboardOCR"), manager: ocrShortcuts.clipboard, allManagers: allHotKeyManagers, feedback: pageFeedback, isRecording: $recordingClipboardOCRShortcut)
                SettingsShortcutRow(title: L10n.text("localImageOCR"), manager: ocrShortcuts.file, allManagers: allHotKeyManagers, feedback: pageFeedback, isRecording: $recordingFileOCRShortcut)
                SettingsShortcutRow(title: L10n.text("openOCRWindow"), manager: ocrShortcuts.openWindow, allManagers: allHotKeyManagers, feedback: pageFeedback, isRecording: $recordingOpenOCRShortcut)
            }
        }
    }
}
