import Foundation

protocol PreferencesDomains {
    func persistentDomain(forName domainName: String) -> [String: Any]?
    func setPersistentDomain(_ domain: [String: Any], forName domainName: String)
}

extension UserDefaults: PreferencesDomains {}

enum PreferencesDomainMigration {
    private static let legacyIdentifier = "local.seven.translator"

    static func migrateIfNeeded(bundleIdentifier: String?, defaults: any PreferencesDomains) {
        let currentIdentifier = AppDataPaths.bundleIdentifier
        guard bundleIdentifier == currentIdentifier,
              defaults.persistentDomain(forName: currentIdentifier)?.isEmpty != false,
              let legacy = defaults.persistentDomain(forName: legacyIdentifier), !legacy.isEmpty else { return }
        // 保留旧域，完整复制后新域已有配置，后续启动不会重做。
        defaults.setPersistentDomain(legacy, forName: currentIdentifier)
    }
}
