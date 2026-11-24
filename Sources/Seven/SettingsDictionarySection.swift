import SwiftUI

extension SettingsView {
    var dictionaryDetail: some View {
        SettingsDetailForm {
            servicePageHeader
        } content: {
            SettingsGroup() {
                SettingsNote(text: L10n.text("lookUpEnglishWordsAndPhrasesOffline"))
                SettingsStatusActionRow(title: L10n.text("offlineDictionary"), status: dictionaryManager.statusText, isError: dictionaryHasError, isLoading: dictionaryManager.state == .downloading || dictionaryManager.state == .verifying) { dictionaryAction }
                if dictionaryManager.state == .importing {
                    SettingsLinearProgress(value: dictionaryManager.progress)
                }
                SettingsDivider()
                SettingsLinkRow(title: L10n.text("source"), text: L10n.text("ecdictLicense"), destination: URL(string: "https://github.com/skywind3000/ECDICT")!)
            }
        }
    }

    private var dictionaryHasError: Bool {
        if case .failed = dictionaryManager.state { return true }
        return false
    }

    @ViewBuilder private var dictionaryAction: some View {
        switch dictionaryManager.state {
        case .notInstalled, .failed:
            Button(L10n.text("downloadDictionary")) { dictionaryManager.install(); model.setServiceEnabled(.ecdict, enabled: true) }
        case .downloading, .verifying, .importing:
            Button(L10n.text("cancelDownload")) { dictionaryManager.cancel() }
        case .ready:
            Button(L10n.text("deleteDictionary"), role: .destructive) { confirmingDictionaryDelete = true }
        }
    }
}
