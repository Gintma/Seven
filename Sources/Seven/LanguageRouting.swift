
/// Automatic target-language rule: translate to the second language if the source is the first language, otherwise translate to the first language.
/// All language parameters use codes from `LanguageCatalog`.
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
        if LanguageCatalog.isChinese(primary), LanguageCatalog.isChinese(secondary) {
            return detected == primary ? secondary : primary
        }
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
