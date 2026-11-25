import AppKit

extension TranslationModel {
    func instance(_ id: TranslationProviderID) -> ServiceInstance? { serviceInstances.first { $0.id == id } }
    @discardableResult
    func addService(_ provider: ServiceProvider) -> TranslationProviderID {
        if provider.isBuiltIn, let existing = serviceInstances.first(where: { $0.provider == provider }) { return existing.id }
        let names = Set(serviceInstances.map(\.name))
        var name = provider.title, number = 2
        while names.contains(name) { name = "\(provider.title) \(number)"; number += 1 }
        let item = ServiceInstance(provider: provider, name: name)
        serviceInstances.append(item)
        expandedProviders.insert(item.id)
        settings.setServiceExpanded(true, provider: item.id)
        persistInstances()
        return item.id
    }
    func updateService(_ item: ServiceInstance) {
        guard let index = serviceInstances.firstIndex(where: { $0.id == item.id }), serviceInstances[index] != item else { return }
        var normalized = item
        let usedNames = Set(serviceInstances.filter { $0.id != item.id }.map(\.name))
        let baseName = item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.provider.title : item.name
        normalized.name = baseName
        var number = 2
        while usedNames.contains(normalized.name) { normalized.name = "\(baseName) \(number)"; number += 1 }
        normalized.baseAddress = ServiceEndpoint.normalizedBase(item.baseAddress)
        if item.provider == .openAI {
            if ![ServiceAPIStyle.openAIResponses, .openAICompatible].contains(item.apiStyle) { normalized.apiStyle = .openAIResponses }
        } else if item.provider != .custom { normalized.apiStyle = item.provider.apiStyle }
        let previous = serviceInstances[index]
        normalized.detectedAPIStyle = previous.baseAddress == normalized.baseAddress && previous.model == normalized.model && previous.apiStyle == normalized.apiStyle
            ? previous.detectedAPIStyle : nil
        serviceTasks[item.id]?.cancel(); serviceTasks[item.id] = nil
        if item.id == .appleTranslation { appleTranslationRequest = nil }
        serviceInstances[index] = normalized
        // 地址/模型/提示词等变化使该项结果失效；其他实例不重发。
        if let index = resultIndex(item.id) {
            serviceResults[index].phase = .idle; serviceResults[index].text = ""; serviceResults[index].dictionaryEntry = nil
            serviceResults[index].issue = nil
        }
        clearConfigurationTestResult()
        persistInstances()
        if let generation { refreshOverallState(generation: generation) }
    }
    func setServiceEnabled(_ id: TranslationProviderID, enabled: Bool) {
        guard let index = serviceInstances.firstIndex(where: { $0.id == id }), serviceInstances[index].enabled != enabled else { return }
        serviceInstances[index].enabled = enabled
        persistInstances()
    }
    func moveServices(from offsets: IndexSet, to destination: Int) {
        let moving = offsets.sorted().compactMap { serviceInstances.indices.contains($0) ? serviceInstances[$0] : nil }
        guard !moving.isEmpty, offsets.allSatisfy({ serviceInstances.indices.contains($0) }), destination >= 0, destination <= serviceInstances.count else { return }
        for index in offsets.sorted(by: >) where serviceInstances.indices.contains(index) { serviceInstances.remove(at: index) }
        serviceInstances.insert(contentsOf: moving, at: min(serviceInstances.count, destination-offsets.filter { $0 < destination }.count))
        persistInstances()
    }
    func hasSavedServiceKey(_ id: TranslationProviderID) -> Bool {
        guard let item = instance(id), !item.provider.isBuiltIn else { return false }
        do { return !(try credentials.read(account: item.configuration.credentialAccount)).isEmpty }
        catch { return true }
    }
    func deleteService(_ id: TranslationProviderID) throws {
        guard let item = instance(id) else { return }
        // 删除凭据失败时不删除实例，让用户仍能重试；词库文件不在此处处理。
        if !item.provider.isBuiltIn {
            try credentials.save("", account: item.configuration.credentialAccount)
        }
        serviceTasks[id]?.cancel(); serviceTasks[id] = nil
        expandedProviders.remove(id)
        settings.removeServiceExpanded(id)
        serviceInstances.removeAll { $0.id == id }
        persistInstances()
    }
    func saveServiceKey(_ id: TranslationProviderID, key: String) throws {
        guard let item = instance(id), !item.provider.isBuiltIn else { return }
        guard !key.contains("\n"), !key.contains("\r") else { throw TranslationError.configuration(.key("theAPIKeyCannotContainLineBreaks")) }
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = try credentials.read(account: item.configuration.credentialAccount)
        try credentials.save(normalized, account: item.configuration.credentialAccount)
        let changed = previous != normalized
        if changed, let index = serviceInstances.firstIndex(where: { $0.id == id }) {
            serviceInstances[index].detectedAPIStyle = nil
            persistInstances()
        }
        clearConfigurationTestResult()
    }
    func rememberVerifiedAPIStyle(_ style: ServiceAPIStyle, configuration: ServiceConfiguration) {
        guard let raw = configuration.instanceID,
              let index = serviceInstances.firstIndex(where: { $0.id.rawValue == raw }),
              serviceInstances[index].provider == .openAI,
              serviceInstances[index].model == configuration.model,
              serviceInstances[index].baseAddress == ServiceEndpoint.normalizedBase(configuration.endpoint),
              [ServiceAPIStyle.openAIResponses, .openAICompatible].contains(style) else { return }
        serviceInstances[index].detectedAPIStyle = style
        persistInstances()
    }

    internal func persistInstances() {
        settings.serviceInstances = serviceInstances
        serviceListDidChange()
    }
}
