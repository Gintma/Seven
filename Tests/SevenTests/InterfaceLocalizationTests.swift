import AppKit
import XCTest
@testable import Seven

final class InterfaceLocalizationTests: XCTestCase {
    func testRegionalSystemLanguagesResolveToSupportedLocalizations() {
        let cases: [(String, InterfaceLanguage)] = [
            ("zh-CN", .simplifiedChinese), ("zh-TW", .traditionalChinese), ("zh-HK", .traditionalChinese),
            ("zh-Hant-MO", .traditionalChinese), ("en-GB", .english), ("ja-JP", .japanese),
            ("ko-KR", .korean), ("es-ES", .spanish), ("es-419", .spanish)
        ]
        for (identifier, expected) in cases {
            XCTAssertEqual(InterfaceLanguage.matchingLocalization(identifier), expected, identifier)
        }
        XCTAssertNil(InterfaceLanguage.matchingLocalization("fr-FR"))
    }

    @MainActor func testAdditionalInterfaceLanguagesPersistAndRender() throws {
        let suite = "SevenTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = InterfaceLanguageState(defaults: defaults)
        let cases: [(InterfaceLanguage, String, String, String)] = [
            (.traditionalChinese, "翻譯服務", "取消", "已取得 2 個模型"),
            (.japanese, "翻訳サービス", "キャンセル", "2 件のモデルが見つかりました"),
            (.korean, "번역 서비스", "취소", "모델 2개를 찾았습니다"),
            (.spanish, "Servicios de traducción", "Cancelar", "Se encontraron 2 modelos")
        ]
        for (language, services, cancel, models) in cases {
            state.select(language)
            XCTAssertEqual(InterfaceLanguage.stored(in: defaults), language)
            L10n.$languageOverride.withValue(language) {
                XCTAssertEqual(L10n.locale.identifier, language.rawValue)
                XCTAssertEqual(SettingsSection.service.title, services)
                XCTAssertEqual(L10n.text("cancel"), cancel)
                XCTAssertEqual(L10n.format("modelCount", Int64(2)), models)
            }
        }
        L10n.$languageOverride.withValue(.spanish) {
            XCTAssertEqual(L10n.format("modelCount", Int64(1)), "Se encontró 1 modelo")
            XCTAssertEqual(L10n.format("timeoutSeconds", Int64(1)), "1 segundo")
            XCTAssertEqual(L10n.format("timeoutSeconds", Int64(2)), "2 segundos")
        }
    }

    func testLocalizedResourcesKeepKeysAndFormatPlaceholdersAligned() throws {
        func readPlist<T>(_ file: String, extension ext: String, in bundle: Bundle) throws -> T {
            let url = try XCTUnwrap(bundle.url(forResource: file, withExtension: ext))
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
            return try XCTUnwrap(plist as? T, url.path)
        }

        let placeholders = try NSRegularExpression(pattern: #"%%|%(?:[1-9]\d*\$@|lld|\.\d+f)|\{\{\w+\}\}|%"#)
        func signature(_ value: String) -> [String] {
            let text = value as NSString
            return placeholders.matches(in: value, range: NSRange(location: 0, length: text.length))
                .map { text.substring(with: $0.range) }.sorted()
        }

        let base = try XCTUnwrap(L10n.resourceBundle(for: .english))
        let baseStrings: [String: String] = try readPlist("Localizable", extension: "strings", in: base)
        let baseInfo: [String: String] = try readPlist("InfoPlist", extension: "strings", in: base)
        let basePlurals: [String: [String: Any]] = try readPlist("Localizable", extension: "stringsdict", in: base)
        for language in InterfaceLanguage.allCases where language != .system {
            let code = language.rawValue
            let bundle = try XCTUnwrap(L10n.resourceBundle(for: language), code)
            let strings: [String: String] = try readPlist("Localizable", extension: "strings", in: bundle)
            let info: [String: String] = try readPlist("InfoPlist", extension: "strings", in: bundle)
            let plurals: [String: [String: Any]] = try readPlist("Localizable", extension: "stringsdict", in: bundle)
            let checksForHan = [.english, .korean, .spanish].contains(language)

            for (reference, translation) in [(baseStrings, strings), (baseInfo, info)] {
                XCTAssertEqual(Set(translation.keys), Set(reference.keys), code)
                for (key, value) in translation {
                    XCTAssertFalse(value.isEmpty, "\(code).\(key)")
                    XCTAssertEqual(signature(value), signature(reference[key] ?? ""), "\(code).\(key)")
                    if checksForHan {
                        XCTAssertNil(value.range(of: #"\p{Han}"#, options: .regularExpression), "\(code).\(key): \(value)")
                    }
                }
            }

            XCTAssertEqual(Set(plurals.keys), Set(basePlurals.keys), code)
            for (key, entry) in plurals {
                let name = "\(code).\(key)"
                XCTAssertEqual(entry["NSStringLocalizedFormatKey"] as? String, "%#@count@", name)
                let forms = try XCTUnwrap(entry["count"] as? [String: String], name)
                XCTAssertEqual(forms["NSStringFormatSpecTypeKey"], "NSStringPluralRuleType", name)
                XCTAssertEqual(forms["NSStringFormatValueTypeKey"], "lld", name)
                let expected: Set<String> = language == .english || language == .spanish ? ["one", "other"] : ["other"]
                let variants = forms.filter { !$0.key.hasPrefix("NSString") }
                XCTAssertEqual(Set(variants.keys), expected, name)
                for (variant, text) in variants {
                    XCTAssertEqual(signature(text), ["%lld"], "\(name).\(variant)")
                    if checksForHan {
                        XCTAssertNil(text.range(of: #"\p{Han}"#, options: .regularExpression), "\(name).\(variant): \(text)")
                    }
                }
            }
        }
    }

    func testShortConnectionReasonKeepsDomainsAndVersions() {
        XCTAssertEqual(
            SettingsConnectionResult.shortReason("Version 2.1 failed at api.example.com. Check the address."),
            "Version 2.1 failed at api.example.com"
        )
    }
}

extension InterfaceLocalizationTests {
    func testBothLanguagesAndPluralFormsLoadFromSwiftPM() {
        L10n.$languageOverride.withValue(.english) {
            XCTAssertEqual(L10n.text("history.title"), "History")
            XCTAssertEqual(L10n.format("modelCount", Int64(1)), "Found 1 model")
            XCTAssertEqual(L10n.format("modelCount", Int64(2)), "Found 2 models")
            XCTAssertEqual(LanguageCatalog.name("en"), "English")
            XCTAssertEqual(SettingsNavigationGroup.translation.title, "Translation")
            XCTAssertEqual(SettingsSection.service.title, "Translation Services")
#if DEBUG || SEVEN_DEVELOPMENT
            XCTAssertEqual(SettingsSection.diagnostics.title, "Diagnostics")
#endif
        }
        L10n.$languageOverride.withValue(.simplifiedChinese) {
            XCTAssertEqual(L10n.text("history.title"), "历史记录")
            XCTAssertEqual(L10n.format("modelCount", Int64(2)), "已获取 2 个模型")
            XCTAssertEqual(LanguageCatalog.name("en"), "英语")
            XCTAssertEqual(SettingsNavigationGroup.translation.title, "翻译")
            XCTAssertEqual(SettingsSection.service.title, "翻译服务")
#if DEBUG || SEVEN_DEVELOPMENT
            XCTAssertEqual(SettingsSection.diagnostics.title, "诊断")
#endif
        }
    }

    @MainActor func testInstalledAppUsesLocalizedResourcesWithoutPackageBundle() throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let english = contents.appendingPathComponent("Resources/en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: english, withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundleIdentifier": "local.seven.test.localization",
            "CFBundlePackageType": "APPL",
            "CFBundleDevelopmentRegion": "zh-Hans"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try #""history.title" = "Main bundle";"#.write(
            to: english.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8
        )
        let bundle = try XCTUnwrap(Bundle(url: app))
        let localized = try XCTUnwrap(L10n.resourceBundle(for: .english, main: bundle) {
            XCTFail("The installed app must not use the SwiftPM bundle")
            return .main
        })
        XCTAssertEqual(localized.localizedString(forKey: "history.title", value: nil, table: nil), "Main bundle")
        XCTAssertNil(L10n.resourceBundle(for: .simplifiedChinese, main: bundle) {
            XCTFail("Missing installed resources must not invoke the SwiftPM accessor")
            return .main
        })
    }

    func testBuiltInDisplayNamesSwitchWithoutRewritingSavedNames() throws {
        let legacyNames: [(ServiceProvider, String, String)] = [
            (.apple, "Apple 翻译", "Apple Translation"),
            (.google, "Google 翻译", "Google Translate"),
            (.youdao, "有道翻译", "Youdao Translate"),
            (.dictionary, "简明英汉词典", "English–Chinese Dictionary")
        ]
        let instances = try legacyNames.map { provider, saved, _ in
            try JSONDecoder().decode(ServiceInstance.self, from: JSONEncoder().encode(
                ServiceInstance(provider: provider, name: saved)
            ))
        }
        let custom = ServiceInstance(provider: .custom, name: "工作")
        L10n.$languageOverride.withValue(.english) {
            XCTAssertEqual(instances.map(\.displayName), legacyNames.map { $0.2 })
            XCTAssertEqual(instances.map(\.name), legacyNames.map { $0.1 })
            XCTAssertEqual(custom.displayName, "工作")
            XCTAssertEqual(ServiceInstance(provider: .custom).displayName, "Custom")
        }
        L10n.$languageOverride.withValue(.simplifiedChinese) {
            XCTAssertEqual(instances.map(\.displayName), legacyNames.map { $0.1 })
        }
    }

    func testStoredErrorsAndOCRFallbackFollowDisplayLanguage() {
        let error = TranslationError.transport(.key("service.requestTimedOut", .key("googleTranslate")))
        let message = LocalizedMessage.forError(error)
        L10n.$languageOverride.withValue(.english) {
            XCTAssertEqual(message.text, "The request to Google Translate timed out. Try again later.")
            XCTAssertEqual(OCRRecognitionLanguages.name("da"), "Danish")
        }
        L10n.$languageOverride.withValue(.simplifiedChinese) {
            XCTAssertEqual(message.text, "Google 翻译请求超时，请稍后重试。")
            XCTAssertEqual(OCRRecognitionLanguages.name("da"), "丹麦语")
        }
    }
}

extension InterfaceLocalizationTests {
    @MainActor func testRefreshingServicePresentationPreservesStreamAndLocalizesFailure() throws {
        let suite = "SevenTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.serviceInstances = [ServiceInstance(provider: .google, name: "Google 翻译")]
        let model = TranslationModel(credentials: UnusedLocalizationCredentialStore(), settings: settings)
        var result = try XCTUnwrap(model.displayedServiceResults.first)
        result.phase = .streaming
        result.text = "partial text"
        result.issue = .key("translation.noServiceResult")
        model.serviceResults = [result]
        model.isLoading = true

        L10n.$languageOverride.withValue(.english) {
            model.refreshServicePresentation()
            XCTAssertEqual(model.serviceResults.first?.title, "Google Translate")
            XCTAssertEqual(model.serviceResults.first?.phase, .streaming)
            XCTAssertEqual(model.serviceResults.first?.text, "partial text")
            XCTAssertTrue(model.isLoading)
            XCTAssertEqual(model.serviceResults.first?.errorMessage, "The service returned no result.")
            XCTAssertEqual(settings.serviceInstances?.first?.name, "Google 翻译")
        }
    }

    @MainActor func testServiceCardRefreshesLocalizedBodyForUnchangedResult() throws {
        _ = NSApplication.shared
        let suite = "SevenTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let service = ServiceInstance(provider: .openAI, name: "OpenAI")
        settings.serviceInstances = [service]
        let model = TranslationModel(credentials: UnusedLocalizationCredentialStore(), settings: settings)
        model.input = "Sample input"
        model.pinned = true

        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

        for (phase, chinese, english) in [
            (TranslationResultPhase.failure, "请填写 API Key。", "Enter an API key."),
            (.cancelled, "已取消", "Canceled")
        ] {
            var result = try XCTUnwrap(model.visibleServices().first)
            result.phase = phase
            if phase == .failure { result.issue = .key("enterAnAPIKey") }
            model.serviceResults = [result]
            let card = AppKitServiceCardView(model: model, provider: service.id)

            L10n.$languageOverride.withValue(.simplifiedChinese) {
                card.apply(result, hasCurrentResult: true, suppressBody: false, animated: false)
            }
            let text = try XCTUnwrap(descendants(card).compactMap { $0 as? NSTextView }.first)
            XCTAssertEqual(text.string, chinese)

            L10n.$languageOverride.withValue(.english) {
                model.refreshServicePresentation()
                card.refreshInterfaceLanguage()
                XCTAssertEqual(model.serviceResults.first, result)
                card.apply(model.serviceResults[0], hasCurrentResult: true, suppressBody: false, animated: false)
                XCTAssertEqual(text.string, english)
                if phase == .failure {
                    let retry = descendants(card).compactMap { $0 as? NSButton }.first { $0.title == "Retry" }
                    XCTAssertEqual(retry?.accessibilityLabel(), "Retry OpenAI")
                }
            }
        }
    }
}

private struct UnusedLocalizationCredentialStore: CredentialStoring {
    func read(account: String) throws -> String {
        XCTFail("Refreshing the interface must not read credentials")
        return ""
    }

    func save(_ value: String, account: String) throws {
        XCTFail("Refreshing the interface must not write credentials")
    }
}
