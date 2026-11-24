import SwiftUI

extension SettingsView {
    var servicePane: some View {
        SettingsServicePage(explanation: L10n.text("enabledServicesAppearInResultsDragTo")) {
            serviceList
        } detail: {
            serviceDetail
        } footer: {
            SettingsServiceActionsRow {
                serviceListActions
            } trailing: {
                if let item = model.instance(selectedService ?? .compatible), !item.provider.isBuiltIn {
                    serviceVerificationRow
                }
            }
        }
        .onChange(of: serviceEditor.apiKey) { _, _ in
            if serviceEditor.hasChanges { pageFeedback.serviceOperation = nil }
        }
        .onChange(of: serviceEditor.value) { _, _ in
            if serviceEditor.hasChanges { pageFeedback.serviceOperation = nil }
        }
        .onChange(of: serviceEditor.sourceRevision) { _, revision in
            if modelCatalogSourceRevision != revision { cancelModelCatalogRequest() }
        }
        .onChange(of: dictionaryManager.state) { _, state in
            if state == .ready { model.setServiceEnabled(.ecdict, enabled: true) }
            model.refreshDictionaryAvailability()
        }
        .confirmationDialog(L10n.format("deleteAndItsAPIKey", String(describing: model.instance(selectedService ?? .compatible)?.displayName ?? L10n.text("service"))), isPresented: $deletingService, titleVisibility: .visible) {
            Button(L10n.text("deleteService"), role: .destructive) { deleteSelectedService() }
            Button(L10n.text("cancel"), role: .cancel) { }
        }
    }
}
