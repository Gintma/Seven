import AppKit

extension TranslationModel {
    // MARK: 服务列表与展开状态

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

    /// 当前设置下出现在结果列表中的服务，按显示顺序排列，均为未运行的占位结果。
    /// 按启用状态及词典/Apple可用性过滤，不检查自备服务配置；配置错误由请求阶段呈现。
    internal func visibleServices() -> [TranslationServiceResult] {
        serviceInstances.compactMap { item in
            guard item.enabled else { return nil }
            if item.provider == .dictionary, !dictionaryService.isAvailable { return nil }
            if item.provider == .apple, !systemTranslationBridgeAvailable { return nil }
            return servicePlaceholder(id: item.id, title: item.displayName, subtitle: item.provider.isBuiltIn ? "" : item.configuration.hostLabel, isTranslation: item.provider != .dictionary)
        }
    }

    /// 设置里启用、停用或重命名服务后，同步已显示的结果列表：
    /// 停用的移除并取消请求；新启用的加入，有原文时只为它发起请求；其余结果保持不变。
    /// 还没有结果时列表由 `displayedServiceResults` 按设置实时生成，无需处理。
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
            // 保留已有结果，只更新标题（例如自备服务改名）。
            current.title = placeholder.title
            current.subtitle = placeholder.subtitle
            return current
        }
        if hasInputText {
            for provider in added {
                // 收起的卡片保持暂停，不发请求（可能消耗付费额度），与正常翻译一致。
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
                // 卡片收起后朗读按钮随之隐藏，正在朗读的内容应一并停止。
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
