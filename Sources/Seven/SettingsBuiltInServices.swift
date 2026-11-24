import SwiftUI

extension SettingsView {
    var youdaoDetail: some View {
        SettingsDetailForm {
            servicePageHeader
        } content: {
            SettingsGroup(L10n.text("dictionaryContent")) {
                SettingsToggleRow(L10n.text("pronunciationAndAudio"), isOn: $model.youdaoShowsPronunciations, explanation: L10n.text("usAndUKPronunciationsWithSeparatePlayback"))
                SettingsDivider()
                SettingsToggleRow(L10n.text("definitions"), isOn: $model.youdaoShowsDefinitions, explanation: L10n.text("examTagsDefinitionsByPartOfSpeech"))
                SettingsDivider()
                SettingsToggleRow(L10n.text("webPhrases"), isOn: $model.youdaoShowsPhrases)
                SettingsDivider()
                SettingsToggleRow(L10n.text("bilingualExamples"), isOn: $model.youdaoShowsExamples, explanation: L10n.text("showEnglishExamplesWithTheirChineseTranslations"))
            }
        }
    }

    var appleDetail: some View {
        SettingsDetailForm {
            servicePageHeader
        } content: {
            SettingsGroup() {
                SettingsNote(text: appleTranslationAvailable ? L10n.text("onDeviceTranslationLanguagePacksAreRequired") : L10n.text("requiresMacOS15OrLater"))
                SettingsDivider()
                SettingsLinkRow(title: "", text: L10n.text("manageDownloadedLanguages"),
                                destination: URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension?translation")!)
            }
        }
    }

    var googleDetail: some View {
        SettingsDetailForm {
            servicePageHeader
        } content: {
            SettingsGroup() {
                SettingsNote(text: L10n.text("translateTextWithoutAnAPIKey"))
            }
        }
    }

    var appleTranslationAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }
}
