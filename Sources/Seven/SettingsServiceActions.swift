import SwiftUI

extension SettingsView {
    func prepareServiceDraft() {
        guard let selectedService, let item = model.instance(selectedService) else { return }
        if serviceEditor.value.id == selectedService, serviceEditor.hasChanges { return }
        cancelModelCatalogRequest()
        pageFeedback.serviceOperation = nil
        serviceLoadIssue = nil
        model.clearConfigurationTestResult()
        pageFeedback.keyIsRevealed = false
        do { try serviceEditor.load(item, using: model) }
        catch { serviceLoadIssue = .forError(error) }
    }

    func finishServiceNameEditing() {
        let name = serviceEditor.value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        serviceEditor.value.name = name.isEmpty ? serviceEditor.value.provider.title : name
    }

    func toggleKeyVisibility() { pageFeedback.keyIsRevealed.toggle() }

    @discardableResult
    func saveServiceDraft() -> Bool {
        do {
            try serviceEditor.save(using: model)
            pageFeedback.serviceOperation = .saved
            return true
        } catch {
            pageFeedback.serviceOperation = .failed(.forError(error))
            return false
        }
    }

    func saveServiceAndDepart() {
        do { try serviceEditor.saveAndDepart(using: model) }
        catch {
            serviceEditor.cancelDeparture()
            pageFeedback.serviceOperation = .failed(.forError(error))
        }
    }

    func requestServiceDeletion() {
        guard let selectedService else { return }
        if model.hasSavedServiceKey(selectedService) { deletingService = true }
        else { deleteSelectedService() }
    }

    func deleteSelectedService() {
        guard let id = selectedService else { return }
        do {
            try model.deleteService(id)
            // Deletion is explicitly confirmed; discard any unsaved draft for this service.
            serviceEditor.discard()
            selectedService = model.serviceInstances.first?.id
            prepareServiceDraft()
        } catch {
            pageFeedback.serviceOperation = .failed(.forError(error))
        }
    }

    func loadModels() {
        let requestID = UUID(), owner = serviceEditor.value.id
        let revision = serviceEditor.sourceRevision
        modelCatalogRequestID = requestID; isLoadingModels = true; modelCatalogIssue = nil
        modelCatalogSourceRevision = revision
        let configuration = serviceEditor.value.configuration
        let credential = serviceEditor.apiKey
        Task { @MainActor in
            do {
                guard modelCatalogRequestID == requestID, selectedService == owner, serviceEditor.sourceRevision == revision else { return }
                let catalog = try await AIModelCatalogService.shared.fetchModels(configuration: configuration, apiKey: credential)
                guard modelCatalogRequestID == requestID, selectedService == owner, serviceEditor.sourceRevision == revision else { return }
                serviceEditor.value.fetchedModels = catalog.models
                modelCatalogIssue = .key("modelCount", .count(catalog.models.count)); modelCatalogMessageIsError = false
            } catch {
                guard modelCatalogRequestID == requestID, selectedService == owner, serviceEditor.sourceRevision == revision else { return }
                modelCatalogIssue = .key("modelCatalogUnavailable"); modelCatalogMessageIsError = true
            }
            isLoadingModels = false
        }
    }

    func cancelModelCatalogRequest() {
        modelCatalogRequestID = nil; modelCatalogSourceRevision = nil
        isLoadingModels = false; modelCatalogIssue = nil
    }

    func testService() {
        pageFeedback.serviceOperation = nil
        do { try serviceEditor.verify(using: model) }
        catch { pageFeedback.serviceOperation = .failed(.forError(error)) }
    }
}
