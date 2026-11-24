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
        let cases: [(InterfaceLanguage, String)] = [
            (.traditionalChinese, "已取得 2 個模型"),
            (.japanese, "2 件のモデルが見つかりました"),
            (.korean, "모델 2개를 찾았습니다"),
            (.spanish, "Se encontraron 2 modelos")
        ]
        for (language, models) in cases {
            state.select(language)
            XCTAssertEqual(InterfaceLanguage.stored(in: defaults), language)
            L10n.$languageOverride.withValue(language) {
                XCTAssertEqual(L10n.locale.identifier, language.rawValue)
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
        let english = L10n.$languageOverride.withValue(.english) {
            XCTAssertEqual(L10n.format("modelCount", Int64(1)), "Found 1 model")
            XCTAssertEqual(L10n.format("modelCount", Int64(2)), "Found 2 models")
            return L10n.text("history.title")
        }
        let chinese = L10n.$languageOverride.withValue(.simplifiedChinese) {
            XCTAssertEqual(L10n.format("modelCount", Int64(2)), "已获取 2 个模型")
            return L10n.text("history.title")
        }
        XCTAssertNotEqual(english, "history.title")
        XCTAssertNotEqual(chinese, "history.title")
        XCTAssertNotEqual(english, chinese)
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
        let legacyNames: [(ServiceProvider, String)] = [
            (.apple, "Apple 翻译"),
            (.google, "Google 翻译"),
            (.youdao, "有道翻译"),
            (.dictionary, "简明英汉词典")
        ]
        let instances = try legacyNames.map { provider, saved in
            try JSONDecoder().decode(ServiceInstance.self, from: JSONEncoder().encode(
                ServiceInstance(provider: provider, name: saved)
            ))
        }
        let custom = ServiceInstance(provider: .custom, name: "工作")
        func verify(_ language: InterfaceLanguage) -> [String] {
            L10n.$languageOverride.withValue(language) {
                XCTAssertEqual(instances.map(\.displayName), legacyNames.map { $0.0.title })
                XCTAssertEqual(instances.map(\.name), legacyNames.map { $0.1 })
                XCTAssertEqual(custom.displayName, custom.name)
                return instances.map(\.displayName)
            }
        }
        XCTAssertNotEqual(verify(.english), verify(.simplifiedChinese))
    }

    func testStoredErrorsAndOCRFallbackFollowDisplayLanguage() {
        let error = TranslationError.transport(.key("service.requestTimedOut", .key("googleTranslate")))
        let message = LocalizedMessage.forError(error)
        let resolve: (InterfaceLanguage) -> (error: String, languageName: String) = { language in
            L10n.$languageOverride.withValue(language) {
                let name = OCRRecognitionLanguages.name("da")
                XCTAssertEqual(name, L10n.locale.localizedString(forIdentifier: "da"))
                XCTAssertEqual(message.text, L10n.format("service.requestTimedOut", L10n.text("googleTranslate")))
                return (message.text, name)
            }
        }
        let english = resolve(.english)
        let chinese = resolve(.simplifiedChinese)
        XCTAssertNotEqual(english.error, chinese.error)
        XCTAssertNotEqual(english.languageName, chinese.languageName)
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
            XCTAssertEqual(model.serviceResults.first?.title, ServiceProvider.google.title)
            XCTAssertEqual(model.serviceResults.first?.phase, .streaming)
            XCTAssertEqual(model.serviceResults.first?.text, "partial text")
            XCTAssertTrue(model.isLoading)
            XCTAssertEqual(model.serviceResults.first?.issue, .key("translation.noServiceResult"))
            XCTAssertEqual(model.serviceResults.first?.errorMessage, L10n.text("translation.noServiceResult"))
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

        for (phase, messageKey) in [
            (TranslationResultPhase.failure, "enterAnAPIKey"),
            (.cancelled, "translation.canceled")
        ] {
            var result = try XCTUnwrap(model.visibleServices().first)
            result.phase = phase
            if phase == .failure { result.issue = .key("enterAnAPIKey") }
            model.serviceResults = [result]
            let card = AppKitServiceCardView(model: model, provider: service.id)

            let text = try XCTUnwrap(screenshotDescendants(of: card).compactMap { $0 as? StreamingResultTextView }.first)
            let chinese = L10n.$languageOverride.withValue(.simplifiedChinese) {
                card.apply(result, hasCurrentResult: true, suppressBody: false, animated: false)
                XCTAssertEqual(text.string, L10n.text(messageKey))
                return text.string
            }

            try L10n.$languageOverride.withValue(.english) {
                model.refreshServicePresentation()
                card.refreshInterfaceLanguage()
                XCTAssertEqual(model.serviceResults.first, result)
                card.apply(model.serviceResults[0], hasCurrentResult: true, suppressBody: false, animated: false)
                XCTAssertEqual(text.string, L10n.text(messageKey))
                XCTAssertNotEqual(text.string, chinese)
                if phase == .failure {
                    let retry = try XCTUnwrap(screenshotDescendants(of: card).compactMap { $0 as? NSButton }
                        .first { $0.action == NSSelectorFromString("retryResult") })
                    XCTAssertEqual(retry.accessibilityLabel(), L10n.format("retry2", result.title))
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
