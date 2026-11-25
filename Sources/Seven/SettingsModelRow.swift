import SwiftUI

enum SettingsModelChoices {
    static func unique(_ values: [String]) -> [String] {
        values.filter { !$0.isEmpty }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    static func groups(current: String, fetched: [String], manual: [String]) -> (catalog: [String], manual: [String]) {
        let manual = unique(manual)
        return (unique([current] + fetched).filter { !manual.contains($0) }, manual)
    }
    static func normalized(_ input: String) -> String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct SettingsModelRow: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    @Binding var text: String
    let models: [String]
    @Binding var manualModels: [String]
    let isFetchingModels: Bool
    let fetch: () -> Void
    var message: String?
    var messageIsError: Bool
    @State private var addingModel = false

    init(text: Binding<String>, models: [String], manualModels: Binding<[String]> = .constant([]),
         isLoading: Bool, fetch: @escaping () -> Void, message: String? = nil, messageIsError: Bool = false) {
        self._text = text; self.models = models; self._manualModels = manualModels
        self.isFetchingModels = isLoading; self.fetch = fetch; self.message = message; self.messageIsError = messageIsError
    }

    private var items: [SettingsServiceMenuItem<String>] {
        let groups = SettingsModelChoices.groups(current: text, fetched: models, manual: manualModels)
        var items: [SettingsServiceMenuItem<String>] = groups.catalog.map { .option($0, $0) }
        if !groups.manual.isEmpty {
            if !items.isEmpty { items.append(.separator) }
            items += groups.manual.map { .option($0, $0) }
        }
        if !items.isEmpty { items.append(.separator) }
        items.append(.action(L10n.text("fetchModels"), enabled: !isFetchingModels, fetch))
        items.append(.action(L10n.text("addModelManually"), enabled: true) { addingModel = true })
        let removable = groups.manual.filter { $0 != text }
        if !removable.isEmpty {
            items.append(.submenu(L10n.text("deleteModel"), removable.map { model in
                .action(model, enabled: true) {
                    guard model != text else { return }
                    manualModels.removeAll { $0 == model }
                }
            }))
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(spacing: Design.Space.m) {
                Text(L10n.text("model")).font(Design.Settings.rowFont)
                Spacer(minLength: Design.Space.s)
                SettingsServiceMenu(title: L10n.text("model"), selection: $text, items: items, placeholder: L10n.text("chooseModel"))
                    .fixedSize().settingsSmartTarget("AXPopUpButton")
            }
            SettingsNote(text: L10n.text("chooseAModelFromTheListOr"), multiline: true)
            if isFetchingModels || message != nil {
                HStack(spacing: Design.Space.s) {
                    if isFetchingModels {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("fetchingModels")).font(Design.Text.note.font).foregroundStyle(ThemeStyle.inkSecondary)
                    } else if let message {
                        SettingsStatus(text: message, isError: messageIsError)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .sheet(isPresented: $addingModel) {
            SettingsAddModelSheet { value in
                if !manualModels.contains(value) { manualModels.append(value) }
                text = value
            }
        }
    }
}

private struct SettingsAddModelSheet: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    let add: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    private var normalized: String { SettingsModelChoices.normalized(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.l) {
            Text(L10n.text("addModel")).font(Design.Text.sectionTitle.font)
            SettingsControlRow(L10n.text("modelName")) {
                SettingsEditableTextField(text: $name, title: L10n.text("modelName"),
                                          placeholder: L10n.text("forExampleGpt4oMini"), autofocus: true, onSubmit: submit)
            }
            SettingsNote(text: L10n.text("enterAModelSupportedByThisService"), multiline: true)
            HStack(spacing: Design.Space.s) {
                Spacer()
                Button(L10n.text("cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("add"), action: submit).keyboardShortcut(.defaultAction).disabled(normalized.isEmpty)
            }
        }.padding(Design.Space.xl).frame(width: Design.Settings.providerGridWidth)
    }
    private func submit() {
        guard !normalized.isEmpty else { return }
        add(normalized)
        dismiss()
    }
}
