import SwiftUI

extension SettingsView {
    @ViewBuilder var serviceDetail: some View {
        if let selectedService, let item = model.instance(selectedService) {
            switch item.provider {
            case .dictionary: dictionaryDetail
            case .apple: appleDetail
            case .youdao: youdaoDetail
            case .google: googleDetail
            default: privateKeyDetail
            }
        } else {
            SettingsServiceEmptyState()
        }
    }

    var servicePageHeader: some View {
        SettingsPageHeader(title: model.instance(serviceEditor.value.id)?.displayName ?? serviceEditor.value.provider.title)
    }

    var privateKeyDetail: some View {
        SettingsDetailForm {
            servicePageHeader
        } content: {
            SettingsGroup() {
                SettingsInputRow(title: L10n.text("name"), text: $serviceEditor.value.name,
                                 onSubmit: finishServiceNameEditing, onEndEditing: finishServiceNameEditing)
                SettingsKeyRow(title: "API Key", text: $serviceEditor.apiKey, focused: $apiKeyFocused,
                               isRevealed: pageFeedback.keyIsRevealed, reveal: toggleKeyVisibility,
                               onSubmit: {})
                SettingsInputRow(title: L10n.text("baseURL"), text: $serviceEditor.value.baseAddress,
                                 placeholder: "https://api.example.com/v1",
                                 explanation: L10n.text("usesTheOfficialEndpointByDefaultYou"),
                                 onSubmit: { serviceEditor.value.baseAddress = ServiceEndpoint.normalizedBase(serviceEditor.value.baseAddress) },
                                 reset: serviceEditor.value.provider.baseAddress.isEmpty ? nil : { serviceEditor.value.baseAddress = serviceEditor.value.provider.baseAddress },
                                 defaultValue: serviceEditor.value.provider.baseAddress,
                                 onEndEditing: { serviceEditor.value.baseAddress = ServiceEndpoint.normalizedBase(serviceEditor.value.baseAddress) })
                    .onChange(of: serviceEditor.value.baseAddress) { _, value in
                        if let base = ServiceEndpoint.pastedBase(value) {
                            if serviceEditor.value.provider == .openAI, let style = ServiceEndpoint.pastedOpenAIStyle(value) { serviceEditor.value.apiStyle = style }
                            serviceEditor.value.baseAddress = base
                        }
                    }
                if serviceEditor.value.provider == .custom {
                    SettingsFixedPickerRow(title: L10n.text("apiFormat"), selection: $serviceEditor.value.apiStyle,
                                           options: ServiceAPIStyle.allCases.map { ($0, $0.title) })
                }
                SettingsModelRow(text: $serviceEditor.value.model, models: serviceEditor.value.fetchedModels, manualModels: $serviceEditor.value.manualModels,
                                 isLoading: isLoadingModels, fetch: loadModels,
                                 message: modelCatalogMessage, messageIsError: modelCatalogMessageIsError).id(serviceEditor.value.id)
                SettingsDivider()
            } footer: {
                if serviceEditor.value.provider == .doubao {
                    SettingsNote(text: L10n.text("copyTheModelIDFromTheInference"))
                }
            }
            SettingsGroup() {
                SettingsSegmentedRow(title: L10n.text("mode"), selection: $serviceEditor.value.mode,
                                       explanation: L10n.text("customPromptsReplaceTheDefaultTranslationInstructions"),
                                       options: TranslationMode.allCases.map { ($0, $0 == .custom ? L10n.text("custom") : $0.title) })
                if serviceEditor.value.mode == .custom {
                    SettingsGroup() {
                        SettingsTextRow(title: L10n.text("systemPrompt"), text: $serviceEditor.value.systemPrompt, placeholder: L10n.text("youAreALanguageTeacherPreserveThe"),
                                        explanation: L10n.text("defineTheRoleRulesAndOutputRequirements"))
                        SettingsTextRow(title: L10n.text("userPrompt"), text: $serviceEditor.value.userPrompt, placeholder: L10n.text("translateTheFollowingTextIntoTargetPreserve"),
                                        explanation: L10n.text("specifyHowToHandleTheInputYou"))
                    } footer: {
                        SettingsPromptVariables()
                    }
                }

                SettingsDivider()
                if !reasoningOptions.isEmpty {
                    SettingsFixedPickerRow(title: L10n.text("reasoningEffort"), selection: Binding(
                        get: { serviceEditor.value.reasoningEffort.flatMap { reasoningOptions.contains($0) ? $0 : nil } },
                        set: { serviceEditor.value.reasoningEffort = $0 }
                    ), explanation: L10n.text("theModelDecidesByDefaultHigherSettings"),
                                           options: [(nil, L10n.text("modelDefault"))] + reasoningOptions.map { (Optional($0), $0.title) })
                }
                if !reasoningOptions.isEmpty { SettingsDivider() }
                SettingsFixedPickerRow(title: L10n.text("timeout"), selection: $serviceEditor.value.timeoutSeconds,
                                       explanation: L10n.text("requestsEndIfTheyExceedTheSelected"),
                                       options: timeoutOptions)
            }
        }
    }

    private var timeoutOptions: [(Int, String)] {
        let standard = [30, 60, 120, 300]
        let current = serviceEditor.value.timeoutSeconds
        return (standard.contains(current) ? [] : [(current, L10n.format("secondsCurrent", String(describing: current)))]) + standard.map { ($0, L10n.format("timeoutSeconds", Int64($0))) }
    }

    private var reasoningOptions: [ReasoningEffort] {
        let config = serviceEditor.value.configuration
        return ServiceReasoning.options(provider: serviceEditor.value.provider, model: serviceEditor.value.model,
                                        style: config.apiStyle)
    }

    var serviceVerificationRow: some View {
        SettingsVerificationRow(isLoading: model.isTestingConfiguration,
                                message: serviceMessage ?? model.configurationTestMessage,
                                succeeded: serviceMessage == nil && model.configurationTestSucceeded,
                                verify: testService, save: { saveServiceDraft() },
                                canSave: serviceEditor.hasChanges,
                                statusMessage: serviceMessageIsError ? nil : serviceMessage)
    }
}
