import Foundation
import Security

protocol CredentialStoring: Sendable {
    func read(account: String) throws -> String
    func save(_ value: String, account: String) throws
}

struct KeychainStore: CredentialStoring {
    let service = "com.crissun.seven.api-key"
    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(account: String) throws -> String {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw keychainError(status) }
        return value
    }

    func save(_ value: String, account: String) throws {
        let query = base(account)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    private func keychainError(_ status: OSStatus) -> TranslationError {
        .configuration(.verbatim("无法读写钥匙串（\(status)）。请解锁钥匙串并允许 Seven 访问后重试。"))
    }
}

enum CredentialStoreFactory {
    static func make() -> CredentialStoring {
        FileCredentialStore()
    }
}

final class SettingsStore {
    private let defaults: UserDefaults
    private let configurationKey = "serviceConfiguration.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var hasServiceInstancesData: Bool { defaults.object(forKey: "serviceInstances.v2") != nil }
    var hasLegacyServicePreferences: Bool {
        [configurationKey, "configured", "appleTranslationEnabled", "ecdictEnabled",
         "youdaoEnabled", "googleEnabled", "customServiceEnabled"]
            .contains { defaults.object(forKey: $0) != nil }
    }

    var serviceInstances: [ServiceInstance]? {
        get {
            guard let data = defaults.data(forKey: "serviceInstances.v2") else { return nil }
            guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
            return items.compactMap { item in
                guard JSONSerialization.isValidJSONObject(item), let encoded = try? JSONSerialization.data(withJSONObject: item) else { return nil }
                return try? JSONDecoder().decode(ServiceInstance.self, from: encoded)
            }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: "serviceInstances.v2") }
        }
    }
    var configuration: ServiceConfiguration {
        get {
            guard let data = defaults.data(forKey: configurationKey),
                  let result = try? JSONDecoder().decode(ServiceConfiguration.self, from: data) else { return .init() }
            return result
        }
        set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: configurationKey) } }
    }
    var configured: Bool {
        get { defaults.bool(forKey: "configured") }
        set { defaults.set(newValue, forKey: "configured") }
    }
    var appleTranslationEnabled: Bool {
        get { defaults.object(forKey: "appleTranslationEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "appleTranslationEnabled") }
    }
    var ecdictEnabled: Bool {
        get {
            if let value = defaults.object(forKey: "ecdictEnabled") as? Bool { return value }
            return false
        }
        set { defaults.set(newValue, forKey: "ecdictEnabled") }
    }
    var youdaoEnabled: Bool {
        get { defaults.object(forKey: "youdaoEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "youdaoEnabled") }
    }
    var youdaoShowsPronunciations: Bool {
        get { defaults.object(forKey: "youdaoShowsPronunciations") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "youdaoShowsPronunciations") }
    }
    var youdaoShowsDefinitions: Bool {
        get { defaults.object(forKey: "youdaoShowsDefinitions") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "youdaoShowsDefinitions") }
    }
    var youdaoShowsPhrases: Bool {
        get { defaults.object(forKey: "youdaoShowsPhrases") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "youdaoShowsPhrases") }
    }
    var youdaoShowsExamples: Bool {
        get { defaults.object(forKey: "youdaoShowsExamples") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "youdaoShowsExamples") }
    }
    var googleEnabled: Bool {
        get { defaults.object(forKey: "googleEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "googleEnabled") }
    }
    var customServiceEnabled: Bool {
        get { defaults.object(forKey: "customServiceEnabled") as? Bool ?? configured }
        set { defaults.set(newValue, forKey: "customServiceEnabled") }
    }
    var inputMaximumHeight: Int {
        get {
            let value = (defaults.object(forKey: "inputMaximumHeight.v2") as? NSNumber)?.intValue
                ?? TranslationWindowLayoutPreferences.defaultInputMaximumHeight
            return TranslationWindowLayoutPreferences.normalizedInputMaximumHeight(value)
        }
        set {
            defaults.set(
                TranslationWindowLayoutPreferences.normalizedInputMaximumHeight(newValue),
                forKey: "inputMaximumHeight.v2"
            )
        }
    }
    var maximumWindowHeightRatio: Double {
        get {
            let value = (defaults.object(forKey: "maximumWindowHeightRatio.v3") as? NSNumber)?.doubleValue
                ?? TranslationWindowLayoutPreferences.defaultMaximumWindowHeightRatio
            return TranslationWindowLayoutPreferences.normalizedMaximumWindowHeightRatio(value)
        }
        set {
            defaults.set(
                TranslationWindowLayoutPreferences.normalizedMaximumWindowHeightRatio(newValue),
                forKey: "maximumWindowHeightRatio.v3"
            )
        }
    }
    func isServiceExpanded(_ provider: TranslationProviderID) -> Bool {
        defaults.object(forKey: "serviceExpanded.\(provider.rawValue).v1") as? Bool ?? true
    }
    func removeServiceExpanded(_ provider: TranslationProviderID) {
        defaults.removeObject(forKey: "serviceExpanded.\(provider.rawValue).v1")
    }
    func setServiceExpanded(_ expanded: Bool, provider: TranslationProviderID) {
        defaults.set(expanded, forKey: "serviceExpanded.\(provider.rawValue).v1")
    }
    var clearTranslationOnDismiss: Bool {
        get { defaults.bool(forKey: "clearTranslationOnDismiss.v1") }
        set { defaults.set(newValue, forKey: "clearTranslationOnDismiss.v1") }
    }
    var pinned: Bool {
        get { defaults.bool(forKey: "pinned") }
        set { defaults.set(newValue, forKey: "pinned") }
    }
    var primaryLanguage: String {
        get { defaults.string(forKey: "primaryLanguage").map(LanguageCatalog.migrate) ?? LanguageRouting.defaultPrimary }
        set { defaults.set(newValue, forKey: "primaryLanguage") }
    }
    /// 语言栏上手动选择的源语言与目标语言（"auto" 为自动），下次打开时沿用。
    var sourceLanguage: String {
        get { validLanguage(defaults.string(forKey: "sourceLanguage.v1")) }
        set { defaults.set(newValue, forKey: "sourceLanguage.v1") }
    }
    var targetLanguage: String {
        get { validLanguage(defaults.string(forKey: "targetLanguage.v1")) }
        set { defaults.set(newValue, forKey: "targetLanguage.v1") }
    }
    /// 原文语言的识别方式（仅本机 / 百度优化 / Google 优化），见 `LanguageDetectionMode`。
    var languageDetectionMode: LanguageDetectionMode {
        get { defaults.string(forKey: LanguageDetectionMode.storageKey).flatMap(LanguageDetectionMode.init(rawValue:)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: LanguageDetectionMode.storageKey) }
    }
    /// 语言栏菜单直接列出的常用语言，按语言目录顺序；未设置或全部无效时用默认值。
    var commonLanguages: [String] {
        get {
            guard let stored = defaults.stringArray(forKey: "commonLanguages.v1") else { return LanguageCatalog.defaultCommon }
            let valid = stored.reduce(into: [String]()) { result, code in
                if LanguageCatalog.language(code) != nil && !result.contains(code) { result.append(code) }
            }
            return valid.isEmpty ? LanguageCatalog.defaultCommon : valid
        }
        set { defaults.set(newValue, forKey: "commonLanguages.v1") }
    }
    private func validLanguage(_ stored: String?) -> String {
        guard let stored, stored == LanguageCatalog.automatic || LanguageCatalog.language(stored) != nil else {
            return LanguageCatalog.automatic
        }
        return stored
    }
    var secondaryLanguage: String {
        get { defaults.string(forKey: "secondaryLanguage").map(LanguageCatalog.migrate) ?? LanguageRouting.defaultSecondary }
        set { defaults.set(newValue, forKey: "secondaryLanguage") }
    }
    var speechEngine: SpeechEngineID {
        get { defaults.string(forKey: "speechEngine.v1").flatMap(SpeechEngineID.init(rawValue:)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "speechEngine.v1") }
    }
    func speechEnglishAccent(for engine: SpeechEngineID) -> SpeechEnglishAccent {
        defaults.string(forKey: "speech.\(engine.rawValue).englishAccent.v1")
            .flatMap(SpeechEnglishAccent.init(rawValue:)) ?? .us
    }
    func setSpeechEnglishAccent(_ accent: SpeechEnglishAccent, for engine: SpeechEngineID) {
        defaults.set(accent.rawValue, forKey: "speech.\(engine.rawValue).englishAccent.v1")
    }
    func speechRate(for engine: SpeechEngineID) -> SpeechRate {
        defaults.string(forKey: "speech.\(engine.rawValue).rate.v1")
            .flatMap(SpeechRate.init(rawValue:)) ?? .normal
    }
    func setSpeechRate(_ rate: SpeechRate, for engine: SpeechEngineID) {
        defaults.set(rate.rawValue, forKey: "speech.\(engine.rawValue).rate.v1")
    }
}
