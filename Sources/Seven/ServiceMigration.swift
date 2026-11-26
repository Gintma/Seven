import Foundation

extension SettingsStore {
    /// 仅迁移服务列表与非密钥配置，不访问凭据。
    /// 一旦已有 v2 列表（含用户主动清空的 []）就不再从旧设置重新添加服务。
    func migrateServiceInstances() -> [ServiceInstance] {
        if hasServiceInstancesData {
            var ids = Set<TranslationProviderID>()
            let repaired = (serviceInstances ?? []).compactMap { item -> ServiceInstance? in
                var item = item
                if item.provider.isBuiltIn, let id = item.provider.builtInID, item.id != id {
                    var replacement = ServiceInstance(provider: item.provider, id: id, name: item.name, enabled: item.enabled)
                    replacement.apply(item.configuration)
                    item = replacement
                }
                guard ids.insert(item.id).inserted else { return nil }
                return item
            }
            serviceInstances = repaired
            return repaired
        }
        let hasLegacyPreferences = hasLegacyServicePreferences
        var instances = [
            ServiceInstance(provider: .dictionary, enabled: ecdictEnabled),
            ServiceInstance(provider: .apple, enabled: appleTranslationEnabled),
            ServiceInstance(provider: .youdao, enabled: !hasLegacyPreferences || youdaoEnabled),
            ServiceInstance(provider: .google, enabled: !hasLegacyPreferences || googleEnabled)
        ]
        if configured {
            let legacy = configuration
            var instance = ServiceInstance(provider: .inferred(from: legacy), id: .compatible, name: legacy.name, enabled: customServiceEnabled)
            instance.apply(legacy)
            // 迁移时保留已有格式（包括通过 Gemini 的 OpenAI 兼容入口配置的旧服务）。
            // 非自定义预设新建后固定格式；旧实例如格式不同则归入自定义，避免改变原请求协议。
            if instance.apiStyle != legacy.apiStyle {
                instance = ServiceInstance(provider: .custom, id: .compatible, name: legacy.name, enabled: customServiceEnabled)
                instance.apply(legacy)
            }
            instances.append(instance)
        }
        serviceInstances = instances
        return instances
    }
}
