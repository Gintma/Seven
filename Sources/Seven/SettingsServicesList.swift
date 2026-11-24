import SwiftUI

extension SettingsView {
    var serviceList: some View {
        SettingsListPanel(items: serviceListItems, selection: Binding(
            get: { selectedService?.rawValue },
            set: { raw in
                let next = raw.map { TranslationProviderID(rawValue: $0) }
                guard next != selectedService else { return }
                serviceEditor.requestDeparture { selectedService = next }
            }
        ), toggle: { raw, enabled in
            let id = TranslationProviderID(rawValue: raw)
            model.setServiceEnabled(id, enabled: enabled)
            if serviceEditor.value.id == id { serviceEditor.value.enabled = enabled }
        }, move: { model.moveServices(from: $0, to: $1) })
    }

    var serviceListActions: some View {
        SettingsListActions(canRemove: selectedService != nil,
                            add: { addingService = true }, remove: requestServiceDeletion)
            .popover(isPresented: $addingService, arrowEdge: .bottom) { addServiceGrid }
    }

    private var serviceListItems: [SettingsSecondaryItem] {
        model.serviceInstances.map { item in
            SettingsSecondaryItem(id: item.id.rawValue, title: item.displayName,
                image: BrandIconRenderer.image(provider: item.provider.builtInID, serviceName: item.brandName, size: Design.Icon.brand),
                enabled: item.enabled)
        }
    }

    var addServiceGrid: some View {
        SettingsProviderGrid(addedProviders: Set(model.serviceInstances.map(\.provider))) { provider in
            addingService = false
            serviceEditor.requestDeparture { selectedService = model.addService(provider) }
        }
    }
}
