
/// 自动目标语言规则：原文是第一语言时译为第二语言，其他情况译为第一语言。
/// 所有语言参数均为 `LanguageCatalog` 中的代码。
enum LanguageRouting {
    static let automaticTarget = LanguageCatalog.automatic
    static let defaultPrimary = LanguageCatalog.defaultPrimary
    static let defaultSecondary = LanguageCatalog.defaultSecondary

    static func resolvedTarget(
        for text: String,
        source: String,
        target: String,
        primary: String,
        secondary: String
    ) -> String {
        guard target == automaticTarget else { return target }
        let detected = source == LanguageCatalog.automatic ? detectedLanguage(for: text, primary: primary, secondary: secondary) : source
        guard let detected else { return primary }
        return sameLanguageFamily(detected, primary) ? secondary : primary
    }

    static func detectedLanguage(for text: String, primary: String = defaultPrimary, secondary: String = defaultSecondary) -> String? {
        LanguageCatalog.detectedCode(for: text, primary: primary, secondary: secondary)
    }

    private static func sameLanguageFamily(_ lhs: String, _ rhs: String) -> Bool {
        if LanguageCatalog.isChinese(lhs), LanguageCatalog.isChinese(rhs) { return true }
        return lhs == rhs
    }
}
