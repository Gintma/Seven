import Foundation
import Combine

/// 服务详情的编辑事务；只有显式保存才写入模型和凭据存储。
@MainActor final class SettingsServiceDraft: ObservableObject {
    @Published var value = ServiceInstance(provider: .custom) {
        didSet {
            guard !isRestoring else { return }
            if value != oldValue { model?.clearConfigurationTestResult() }
            if value.requiresModelCatalogInvalidation(comparedTo: oldValue) {
                value.fetchedModels = []
                sourceRevision = UUID()
            }
            if value.baseAddress != oldValue.baseAddress || value.apiStyle != oldValue.apiStyle || value.model != oldValue.model {
                value.detectedAPIStyle = nil
            }
        }
    }
    @Published var apiKey = "" {
        didSet {
            guard !isRestoring, apiKey != oldValue else { return }
            model?.clearConfigurationTestResult()
            value.fetchedModels = []
            value.detectedAPIStyle = nil
            sourceRevision = UUID()
        }
    }
    @Published private(set) var sourceRevision = UUID()
    @Published var confirmsDeparture = false
    private var baseline: ServiceInstance?
    private var savedKey = ""
    private var keyLoaded = false
    private var isRestoring = false
    private var pendingDeparture: (() -> Void)?
    private weak var model: TranslationModel?

    var hasChanges: Bool {
        guard let baseline, !value.provider.isBuiltIn else { return false }
        var comparable = value
        // 勾选开关即时保存；协议探测状态属于模型，不属于用户草稿。
        comparable.enabled = baseline.enabled
        comparable.detectedAPIStyle = baseline.detectedAPIStyle
        return comparable != baseline || apiKey != savedKey
    }

    func load(_ item: ServiceInstance, using model: TranslationModel) throws {
        self.model = model
        isRestoring = true
        defer { isRestoring = false }
        value = item; baseline = item
        apiKey = ""; savedKey = ""; keyLoaded = item.provider.isBuiltIn
        sourceRevision = UUID()
        if !item.provider.isBuiltIn {
            let key = try model.readCredential(for: item.configuration.credentialAccount)
            apiKey = key; savedKey = key; keyLoaded = true
        }
    }

    func save(using model: TranslationModel) throws {
        guard let current = model.instance(value.id), !current.provider.isBuiltIn else {
            throw TranslationError.configuration(.key("thisServiceIsNoLongerAvailableSelect"))
        }
        guard keyLoaded else {
            throw TranslationError.configuration(.key("couldNotReadTheSavedAPIKey"))
        }
        // 凭据写入可失败，必须在配置更新前完成；失败时保持草稿和已保存配置。
        if apiKey != savedKey { try model.saveServiceKey(value.id, key: apiKey) }
        var saved = value
        saved.enabled = current.enabled
        model.updateService(saved)
        if let normalized = model.instance(value.id) {
            isRestoring = true
            value = normalized; baseline = normalized
            apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines); savedKey = apiKey
            isRestoring = false
        }
    }

    func verify(using model: TranslationModel) throws {
        guard keyLoaded else { throw TranslationError.configuration(.key("couldNotReadTheAPIKeySelect")) }
        model.testConfiguration(value.configuration, key: apiKey, persistVerifiedStyle: false)
    }

    func discard() {
        guard let baseline else { return }
        isRestoring = true
        value = baseline; apiKey = savedKey
        sourceRevision = UUID()
        isRestoring = false
    }

    func requestDeparture(_ action: @escaping () -> Void) {
        guard hasChanges else { action(); return }
        guard pendingDeparture == nil else { return }
        pendingDeparture = action
        confirmsDeparture = true
    }

    func cancelDeparture() {
        pendingDeparture = nil; confirmsDeparture = false
    }

    func discardAndDepart() {
        discard()
        finishDeparture()
    }

    func saveAndDepart(using model: TranslationModel) throws {
        try save(using: model)
        finishDeparture()
    }

    private func finishDeparture() {
        let action = pendingDeparture
        cancelDeparture()
        action?()
    }
}
