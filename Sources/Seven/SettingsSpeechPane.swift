import SwiftUI

extension SettingsView {
    var speechPane: some View { SettingsSpeechPane(speech: model.speech) }
}

/// 直接观察朗读状态；服务能力和选项只读取 SpeechEngineCatalog。
private struct SettingsSpeechPane: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    @ObservedObject var speech: SpeechController
    @State private var selection: SpeechEngineID = .system
    private var selectedEngine: SpeechEngineDescriptor { SpeechEngineCatalog.descriptor(for: selection) }

    var body: some View {
        SettingsServicePage(explanation: L10n.text("ifTheSelectedServiceCannotReadThe")) {
            SettingsListPanel(items: listItems, selection: Binding(
                get: { selection.rawValue }, set: { if let raw = $0, let id = SpeechEngineID(rawValue: raw) { selection = id } }
            ), toggle: { raw, enabled in
                guard let engine = SpeechEngineID(rawValue: raw) else { return }
                speech.selectEngine(enabled ? engine : .system)
            })
        } detail: {
            serviceDetail
        }
        .onAppear { selection=speech.engineID }
    }
    private var listItems: [SettingsSecondaryItem] {
        [true, false].flatMap { online in
            [SettingsSecondaryItem(id: online ? "online" : "offline", title: online ? L10n.text("online") : L10n.text("offline"), isGroup: true)] +
            SpeechEngineCatalog.all.filter { $0.isOnline == online }.map { engine in
                SettingsSecondaryItem(id: engine.id.rawValue, title: engine.title,
                    image: BrandIconRenderer.image(for: ServiceBrandIconCatalog.speechTile(for: engine.id), size: Design.Icon.brand),
                    enabled: speech.engineID == engine.id,
                    allowsToggle: engine.id != .system || speech.engineID != .system,
                    accessibilityStatus: speech.engineID == engine.id ? L10n.text("preferredSpeechService") : L10n.text("availableAsAFallback"))
            }
        }
    }
    private var serviceDetail: some View {
        SettingsDetailForm {
            SettingsPageHeader(title: selectedEngine.title)
        } content: {
            if !selectedEngine.options.isEmpty {
                SettingsGroup() {
                    ForEach(Array(selectedEngine.options.enumerated()), id: \.element) { index, option in
                        if index > 0 { SettingsDivider() }
                        optionControl(option)
                    }
                }
                SettingsDivider()
            }
            SettingsGroup(L10n.text("capabilities")) {
                SettingsValueRow(title: L10n.text("characterLimit"), value: selectedEngine.maximumCharacters.map { L10n.format("characterLimitValue", Int64($0)) } ?? L10n.text("unlimited"))
                SettingsDivider()
                SettingsExpandableTextRow(summary: L10n.format("supportedLanguageCount", Int64(selectedEngine.supportedLanguages.count)),
                                          text: selectedEngine.supportedLanguages.map(LanguageCatalog.name).joined(separator: "、"),
                                          accessibilityLabel: L10n.text("supportedLanguages"))
                    .id(selection)
            } footer: {
                SettingsPrivacyNote(text: privacyText, detail: privacyDetail)
            }
        }
    }
    private var privacyText: String {
        if let host=selectedEngine.host { return L10n.format("requiresAnInternetConnectionTextIsSent", String(describing: host)) }
        return L10n.text("ifOnDeviceSpeechIsUnavailableSeven")
    }
    private var privacyDetail: String {
        let hosts=SpeechEngineCatalog.all.compactMap(\.host).joined(separator: "、")
        return L10n.format("systemSpeechUsesOnDeviceVoicesFirst", String(describing: hosts))
    }
    @ViewBuilder private func optionControl(_ option: SpeechEngineOption) -> some View {
        switch option {
        case .englishAccent:
            SettingsSegmentedRow(title: L10n.text("englishAccent"), selection: Binding(get: { speech.englishAccent(for: selection) }, set: { speech.setEnglishAccent($0, for: selection) }),
                                 options: SpeechEnglishAccent.allCases.map { ($0, $0.title) })
        case .rate:
            SettingsSegmentedRow(title: L10n.text("speakingRate"), selection: Binding(get: { speech.rate(for: selection) }, set: { speech.setRate($0, for: selection) }),
                                 options: SpeechRate.allCases.map { ($0, $0.title) })
        }
    }
}
