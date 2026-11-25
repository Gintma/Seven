import XCTest
@testable import Seven

final class LanguageRoutingTests: XCTestCase {
    func testAutomaticChinesePairUsesOppositeExactVariant() {
        for (primary, secondary) in [("zh-Hant", "zh-Hans"), ("zh-Hans", "zh-Hant")] {
            XCTAssertEqual(LanguageRouting.resolvedTarget(for: "", source: primary, target: "auto",
                                                         primary: primary, secondary: secondary), secondary)
            XCTAssertEqual(LanguageRouting.resolvedTarget(for: "", source: secondary, target: "auto",
                                                         primary: primary, secondary: secondary), primary)
        }
    }

    func testChineseRoutesToSecondaryLanguage() {
        XCTAssertEqual(
            LanguageRouting.resolvedTarget(
                for: "好的翻译应当准确自然。",
                source: "auto",
                target: LanguageRouting.automaticTarget,
                primary: "zh-Hans",
                secondary: "en"
            ),
            "en"
        )
    }

    func testEnglishRoutesToPrimaryLanguage() {
        XCTAssertEqual(
            LanguageRouting.resolvedTarget(
                for: "A good translation preserves meaning and tone.",
                source: "auto",
                target: LanguageRouting.automaticTarget,
                primary: "zh-Hans",
                secondary: "en"
            ),
            "zh-Hans"
        )
    }

    func testManualSourceAvoidsDetection() {
        XCTAssertEqual(
            LanguageRouting.resolvedTarget(
                for: "短文本",
                source: "zh-Hans",
                target: LanguageRouting.automaticTarget,
                primary: "zh-Hans",
                secondary: "en"
            ),
            "en"
        )
    }

    func testManualTargetIsNeverOverridden() {
        XCTAssertEqual(
            LanguageRouting.resolvedTarget(
                for: "中文",
                source: "auto",
                target: "ja",
                primary: "zh-Hans",
                secondary: "en"
            ),
            "ja"
        )
    }

    func testChineseVariantsShareOneLanguageFamily() {
        XCTAssertEqual(
            LanguageRouting.resolvedTarget(
                for: "繁體中文內容",
                source: "zh-Hant",
                target: LanguageRouting.automaticTarget,
                primary: "zh-Hans",
                secondary: "en"
            ),
            "en"
        )
    }
}

final class LanguageCatalogTests: XCTestCase {
    func testOldSavedNamesMigrateToCodes() {
        XCTAssertEqual(LanguageCatalog.migrate("English"), "en")
        XCTAssertEqual(LanguageCatalog.migrate("繁體中文"), "zh-Hant")
        XCTAssertEqual(LanguageCatalog.migrate("自动选择"), LanguageCatalog.automatic)
        XCTAssertEqual(LanguageCatalog.migrate("ja"), "ja", "已是代码的值保持不变")
    }

    func testSettingsReadOldNamesAsCodes() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("日本語", forKey: "primaryLanguage")
        defaults.set("English", forKey: "secondaryLanguage")
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.primaryLanguage, "ja")
        XCTAssertEqual(settings.secondaryLanguage, "en")
    }

    func testCatalogHasUniqueCodesAndCompleteNames() {
        let languages = LanguageCatalog.all
        XCTAssertFalse(languages.isEmpty)
        XCTAssertEqual(Set(languages.map(\.code)).count, languages.count)
        XCTAssertEqual(Set(languages.map(\.name)).count, languages.count)
        for language in languages {
            XCTAssertFalse(language.googleCode?.isEmpty ?? true, language.code)
            XCTAssertFalse(language.name.isEmpty)
            XCTAssertFalse(language.promptName.isEmpty)
        }
    }

}
