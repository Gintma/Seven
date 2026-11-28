import Foundation

extension SettingsStore {
    /// Migrates only the service list and non-secret configuration without accessing credentials.
    /// Once a v2 list exists (including an explicit user-cleared []), never re-add services from legacy settings.
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
            // Preserve the existing wire format during migration (including legacy services configured via Gemini's OpenAI-compatible endpoint).
            // Non-custom presets have a fixed format when newly created; legacy instances with a different format become custom so their original request protocol stays unchanged.
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
