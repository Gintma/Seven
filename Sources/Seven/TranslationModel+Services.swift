import AppKit

extension TranslationModel {
    // MARK: Service List & Expansion State

    func isServiceExpanded(_ provider: TranslationProviderID) -> Bool {
        expandedProviders.contains(provider)
    }

    func refreshServicePresentation() {
        let presentation = Dictionary(uniqueKeysWithValues: visibleServices().map { ($0.id, $0) })
        serviceResults = serviceResults.map { result in
            guard let labels = presentation[result.id] else { return result }
            var result = result
            result.title = labels.title
            result.subtitle = labels.subtitle
            if result.id == .ecdict, let entry = result.dictionaryEntry {
                result.text = entry.formattedText
            }
            return result
        }
    }

    var displayedServiceResults: [TranslationServiceResult] {
        guard serviceResults.isEmpty else { return serviceResults }
        return visibleServices()
    }

    /// Services included in the results list under current settings, in display order, as idle placeholder results.
    /// Filters by enabled state and dictionary/Apple availability without validating BYOK configuration; config errors are surfaced during requests.
    internal func visibleServices() -> [TranslationServiceResult] {
        serviceInstances.compactMap { item in
            guard item.enabled else { return nil }
            if item.provider == .dictionary, !dictionaryService.isAvailable { return nil }
            if item.provider == .apple, !systemTranslationBridgeAvailable { return nil }
            return servicePlaceholder(id: item.id, title: item.displayName, subtitle: item.provider.isBuiltIn ? "" : item.configuration.hostLabel, isTranslation: item.provider != .dictionary)
        }
    }

    /// Syncs the displayed results list after enabling, disabling, or renaming services in Settings:
    /// removes disabled services and cancels their requests; adds newly enabled ones and queries only them if source text exists; leaves others unchanged.
    /// When no results exist yet, the list is generated live from settings by `displayedServiceResults`, so nothing needs updating.
    internal func serviceListDidChange() {
        guard !serviceResults.isEmpty else { return }
        let wanted = visibleServices()
        let wantedIDs = Set(wanted.map(\.id))
        for removed in serviceResults where !wantedIDs.contains(removed.id) {
            serviceTasks[removed.id]?.cancel()
            serviceTasks[removed.id] = nil
            if removed.id == .appleTranslation { appleTranslationRequest = nil }
            if primaryResultID == removed.id { primaryResultID = nil }
            retryAfterDetection.removeAll { $0 == removed.id }
        }
        let existing = Dictionary(uniqueKeysWithValues: serviceResults.map { ($0.id, $0) })
        let added = wanted.filter { existing[$0.id] == nil }.map(\.id)
        serviceResults = wanted.map { placeholder in
            guard var current = existing[placeholder.id] else { return placeholder }
            // Keep existing results and update only the title (e.g., when a BYOK service is renamed).
            current.title = placeholder.title
            current.subtitle = placeholder.subtitle
            return current
        }
        if hasInputText {
            for provider in added {
                // Keep collapsed cards paused without sending requests (which may consume paid quota), matching normal translation behavior.
                if isServiceExpanded(provider) {
                    retryResult(provider)
                } else if let index = resultIndex(provider) {
                    serviceResults[index].phase = .skipped
                    serviceResults[index].issue = Self.pausedServiceIssue
                }
            }
        }
        if let generation { refreshOverallState(generation: generation) }
    }

    func hasCurrentResult(_ provider: TranslationProviderID) -> Bool {
        serviceResults.contains { $0.id == provider }
    }

    func setServiceExpanded(_ provider: TranslationProviderID, expanded: Bool) {
        if expanded != isServiceExpanded(provider) {
            if expanded {
                expandedProviders.insert(provider)
            } else {
                expandedProviders.remove(provider)
                // Collapsing a card hides its speech button, so stop any active speech playback as well.
                if speech.isActive(.result(of: provider)) { speech.stop() }
            }
            settings.setServiceExpanded(expanded, provider: provider)
        }

        guard expanded else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !hasCurrentResult(provider) {
            let placeholders = displayedServiceResults
            guard placeholders.contains(where: { $0.id == provider }) else { return }
            serviceResults = placeholders
        }
        guard let result = serviceResults.first(where: { $0.id == provider }) else { return }
        guard result.phase == .idle || result.phase == .skipped || result.phase == .cancelled else { return }
        retryResult(provider)
    }

    private func servicePlaceholder(
        id: TranslationProviderID,
        title: String,
        subtitle: String = "",
        isTranslation: Bool
    ) -> TranslationServiceResult {
        .init(
            id: id,
            title: title,
            subtitle: subtitle,
            isTranslation: isTranslation,
            phase: .idle,
            text: "",
            dictionaryEntry: nil,
            errorMessage: nil
        )
    }

    func setSystemTranslationBridgeAvailable(_ available: Bool) {
        guard available != systemTranslationBridgeAvailable else { return }
        systemTranslationBridgeAvailable = available
        objectWillChange.send()
    }

    func refreshDictionaryAvailability() {
        objectWillChange.send()
        serviceListDidChange()
    }
}
