import SwiftUI
import AppKit

extension SettingsView {
    var translationPane: some View {
        SettingsForm {
            SettingsGroup(L10n.text("automaticTargetLanguage"), description: L10n.text("whenTheTargetIsSetToChoose")) {
                SettingsLanguagePickerRow(title: L10n.text("firstLanguage"), model: model, selection: Binding(get: { model.primaryLanguage }, set: model.setPrimaryLanguage))
                SettingsLanguagePickerRow(title: L10n.text("secondLanguage"), model: model, selection: Binding(get: { model.secondaryLanguage }, set: model.setSecondaryLanguage))
            }
            SettingsGroup(L10n.text("languageDetection")) {
                SettingsPickerRow(L10n.text("detectionMethod"), selection: $model.languageDetectionMode,
                                  titleNote: L10n.text("ifOnDeviceDetectionIsUncertainSeven")) {
                    ForEach(LanguageDetectionMode.allCases) { Text($0.title).tag($0) }
                }
            }
            SettingsGroup(L10n.text("translateScreenshot")) {
                SettingsToggleRow(L10n.text("smartSelection"), isOn: $translationSmartSelectionEnabled, explanation: L10n.text("detectInterfaceElementsAutomatically"))
            }
            SettingsGroup(L10n.text("favoriteLanguages")) {
                SettingsCommonLanguages(model: model)
            }
            SettingsGroup(L10n.text("window")) {
                SettingsSegmentedRow(title: L10n.text("windowPosition"), selection: Binding(get: { panelPlacement }, set: { panelPlacement=$0; $0.save() }),
                                     options: PanelPlacementMode.allCases.map { ($0, $0.title) })
                .help(L10n.text("rememberLastPositionReturnsTheWindowTo"))
                SettingsSliderRow(title: L10n.text("maximumInputHeight"), value: Binding(
                    get: { Double(model.inputMaximumHeight) }, set: { model.setInputMaximumHeight(Int($0.rounded())) }
                ), range: Double(TranslationWindowLayoutPreferences.minimumInputMaximumHeight)...Double(TranslationWindowLayoutPreferences.maximumInputMaximumHeight), valueLabel: L10n.format("approximateLineCount", Int64(approximateInputLineCount)))
                .help(L10n.text("theInputGrowsWithYourTextIt"))
                SettingsSliderRow(title: L10n.text("maximumWindowHeight"), value: Binding(
                    get: { model.maximumWindowHeightRatio }, set: { model.setMaximumWindowHeightRatio($0) }
                ), range: TranslationWindowLayoutPreferences.minimumWindowHeightRatio...TranslationWindowLayoutPreferences.maximumWindowHeightRatio,
                                  valueLabel: L10n.format("ofScreenHeight", String(describing: Int((model.maximumWindowHeightRatio * 100).rounded()))))
            }
            SettingsGroup(L10n.text("keyboardShortcuts")) {
                SettingsShortcutRow(title: L10n.text("translateAndReplace"), manager: replacementHotKeyManager, allManagers: allHotKeyManagers, feedback: pageFeedback, isRecording: $recordingReplacementShortcut,
                                    explanation: L10n.text("replaceTextWithItsTranslationInsideAnother"),
                                    explanationHelp: L10n.text("sevenReplacesSelectedTextOrTheEntire"))
                SettingsShortcutRow(title: L10n.text("translateTypedText"), manager: inputHotKeyManager, allManagers: allHotKeyManagers, feedback: pageFeedback, isRecording: $recordingInputShortcut)
                SettingsShortcutRow(title: L10n.text("translateSelection"), manager: hotKeyManager, allManagers: allHotKeyManagers, feedback: pageFeedback, isRecording: $recordingShortcut)
                SettingsShortcutRow(title: L10n.text("translateScreenshot"), manager: screenshotHotKeyManager, allManagers: allHotKeyManagers, feedback: pageFeedback, isRecording: $recordingScreenshotShortcut)
            }
        }
    }
    private var approximateInputLineCount: Int {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: Design.Text.content.nsFont)
        return max(1, Int(((CGFloat(model.inputMaximumHeight) - Design.Space.m * 2) / lineHeight).rounded()))
    }
}
