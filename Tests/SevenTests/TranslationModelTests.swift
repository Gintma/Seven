import Foundation
import XCTest
@testable import Seven

@MainActor private final class MemoryCredentials: @preconcurrency CredentialStoring {
    var values: [String: String] = [:]
    private(set) var readCount = 0
    func read(account: String) throws -> String {
        readCount += 1
        return values[account, default: ""]
    }
    func save(_ value: String, account: String) throws { values[account] = value }
}

private actor ControlledService: TranslationServing {
    private var continuation: CheckedContinuation<String, Error>?
    func translateStream(_ request: TranslationRequest, onUpdate: @escaping @Sendable (String) async -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ value: String) { continuation?.resume(returning: value); continuation = nil }
}

private final class ImmediateService: TranslationServing {
    let response: String
    init(response: String) { self.response = response }
    func translateStream(_ request: TranslationRequest, onUpdate: @escaping @Sendable (String) async -> Void) async throws -> String { response }
}

private struct ImmediateDictionaryService: DictionaryServing {
    let entry: DictionaryEntry?

    func lookup(_ text: String) async -> DictionaryEntry? { entry }
}

private struct FailingDictionaryService: DictionaryServing {
    func lookup(_ text: String) async throws -> DictionaryEntry? {
        throw ECDictionaryError.database("database disk image is malformed")
    }
}

private struct ImmediateOnlineService: OnlineTranslationServing {
    let response: String

    func translate(_ request: OnlineTranslationRequest) async throws -> OnlineTranslationOutput {
        .init(text: response, dictionaryEntry: nil)
    }
}

private actor FailOnceOnlineService: OnlineTranslationServing {
    private(set) var attempts = 0

    func translate(_ request: OnlineTranslationRequest) async throws -> OnlineTranslationOutput {
        attempts += 1
        if attempts == 1 {
            throw TranslationError.transport("临时网络错误")
        }
        return .init(text: "有道恢复结果", dictionaryEntry: nil)
    }
}

private actor CountingOnlineService: OnlineTranslationServing {
    private(set) var attempts = 0
    let response: String

    init(response: String) {
        self.response = response
    }

    func translate(_ request: OnlineTranslationRequest) async throws -> OnlineTranslationOutput {
        attempts += 1
        return .init(text: response, dictionaryEntry: nil)
    }
}

private actor GatedOnlineService: OnlineTranslationServing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var firstFinishRequested = false
    private(set) var attempts = 0

    func translate(_ request: OnlineTranslationRequest) async throws -> OnlineTranslationOutput {
        attempts += 1
        if attempts == 1, !firstFinishRequested {
            await withCheckedContinuation { continuation = $0 }
        }
        return .init(text: "后台结果 \(attempts)", dictionaryEntry: nil)
    }

    func finishFirstRequest() {
        firstFinishRequested = true
        continuation?.resume()
        continuation = nil
    }
}

private actor RetryService: TranslationServing {
    private(set) var attempts = 0

    func translateStream(_ request: TranslationRequest, onUpdate: @escaping @Sendable (String) async -> Void) async throws -> String {
        attempts += 1
        if attempts == 1 {
            throw TranslationError.transport("临时网络错误")
        }
        return "恢复后的译文"
    }
}

private final class ImmediateStreamingService: TranslationServing {
    func translateStream(
        _ request: TranslationRequest,
        onUpdate: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        await onUpdate("你好")
        await onUpdate("你好世界")
        return "你好世界"
    }
}

private actor GatedStreamingService: TranslationServing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finishRequested = false


    func translateStream(
        _ request: TranslationRequest,
        onUpdate: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        await onUpdate("你好")
        if !finishRequested {
            await withCheckedContinuation { continuation = $0 }
        }
        await onUpdate("你好世界")
        return "你好世界"
    }

    func finish() {
        finishRequested = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class TranslationModelTests: XCTestCase {
    private func waitUntilIdle(_ model: TranslationModel) async throws {
        for _ in 0..<100 where model.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @discardableResult private func installService(on model: TranslationModel, configuration: ServiceConfiguration, key: String?) throws -> TranslationProviderID {
        let id = model.serviceInstances.first { !$0.provider.isBuiltIn }?.id ?? model.addService(.custom)
        var item = try XCTUnwrap(model.instance(id))
        item.apply(configuration); model.updateService(item)
        if let key { try model.saveServiceKey(id, key: key) }
        return id
    }

    func testConfigurationIsPersistedAndCredentialSeparated() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let credentials = MemoryCredentials()
        let model = TranslationModel(service: ControlledService(), credentials: credentials, settings: settings)
        let configuration = ServiceConfiguration(name: "Test", endpoint: "https://api.example.com/v1/chat/completions", model: "model")

        try installService(on: model, configuration: configuration, key: "top-secret")

        let saved = try XCTUnwrap(settings.serviceInstances?.first { !$0.provider.isBuiltIn })
        XCTAssertEqual(saved.name, configuration.name)
        XCTAssertEqual(saved.configuration.endpoint, configuration.endpoint)
        XCTAssertEqual(try credentials.read(account: saved.configuration.credentialAccount), "top-secret")
        XCTAssertNil(defaults.data(forKey: "top-secret"))
    }

    func testWindowLayoutPreferencesPersistAndUseCurrentScreenHeight() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let model = TranslationModel(
            service: ControlledService(),
            credentials: MemoryCredentials(),
            settings: settings
        )

        model.setInputMaximumHeight(300)
        model.setMaximumWindowHeightRatio(0.73)
        model.updatePanelScreenHeight(1_000)

        XCTAssertEqual(model.inputMaximumHeight, 300)
        XCTAssertEqual(model.maximumWindowHeightRatio, 0.73, accuracy: 0.0001)
        XCTAssertEqual(model.panelScreenHeight, 1_000)
        XCTAssertEqual(TranslationWindowLayoutPreferences.maximumPanelHeight(screenHeight: model.panelScreenHeight, ratio: model.maximumWindowHeightRatio), 730, accuracy: 0.0001)
        XCTAssertEqual(settings.inputMaximumHeight, 300)
        XCTAssertEqual(settings.maximumWindowHeightRatio, 0.73, accuracy: 0.0001)

        let restored = TranslationModel(
            service: ControlledService(),
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults)
        )
        XCTAssertEqual(restored.inputMaximumHeight, 300)
        XCTAssertEqual(restored.maximumWindowHeightRatio, 0.73, accuracy: 0.0001)
    }

    func testUpdatingServiceConfigurationKeepsItsStoredCredential() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryCredentials()
        let model = TranslationModel(service: ControlledService(), credentials: credentials, settings: SettingsStore(defaults: defaults))
        let id = model.addService(.custom)
        try model.saveServiceKey(id, key: "keep-me")
        var item = try XCTUnwrap(model.instance(id))
        let account = item.configuration.credentialAccount
        item.name = "Renamed"; item.baseAddress = "https://other.example.com/v1"; item.model = "new-model"
        model.updateService(item)
        XCTAssertEqual(model.instance(id)?.configuration.credentialAccount, account)
        XCTAssertEqual(try model.readCredential(for: account), "keep-me")
    }

    func testCredentialReadsObserveExternalChanges() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryCredentials()
        credentials.values["account"] = "secret"
        let model = TranslationModel(
            service: ControlledService(), credentials: credentials,
            settings: SettingsStore(defaults: defaults)
        )

        XCTAssertEqual(try model.readCredential(for: "account"), "secret")
        credentials.values["account"] = "changed"
        XCTAssertEqual(try model.readCredential(for: "account"), "changed")
        XCTAssertEqual(credentials.readCount, 2)
    }

    func testZhipuHasNoBundledCredential() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = TranslationModel(
            service: ControlledService(),
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults)
        )
        let configuration = ServiceConfiguration(
            name: "智谱 GLM",
            endpoint: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
            model: "glm-5.3"
        )

        let credential = try model.resolvedCredential(for: configuration)

        XCTAssertTrue(credential.isEmpty)
    }

    func testSavingCredentialReadsBackNewValue() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryCredentials()
        let configuration = ServiceConfiguration(
            name: "Test",
            endpoint: "https://api.example.com/v1/chat/completions",
            model: "model"
        )
        credentials.values[configuration.credentialAccount] = "old"
        let model = TranslationModel(
            service: ControlledService(), credentials: credentials,
            settings: SettingsStore(defaults: defaults)
        )
        XCTAssertEqual(try model.readCredential(for: configuration.credentialAccount), "old")

        try installService(on: model, configuration: configuration, key: "new")

        let item = try XCTUnwrap(model.serviceInstances.first { !$0.provider.isBuiltIn })
        XCTAssertEqual(try model.readCredential(for: item.configuration.credentialAccount), "new")
    }

    func testOlderResultCannotOverwriteNewerState() async throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledService()
        let model = TranslationModel(service: service, credentials: MemoryCredentials(), settings: SettingsStore(defaults: defaults))
        let configuration = ServiceConfiguration(name: "Test", endpoint: "https://api.example.com/v1/chat/completions", model: "model")
        try installService(on: model, configuration: configuration, key: "")
        model.updateInput("first")
        model.translate()
        XCTAssertTrue(model.isLoading)
        model.updateInput("second")
        await service.finish("stale")
        await Task.yield()

        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.serviceResults.isEmpty)
    }

    func testRetryAfterNetworkFailureStartsFreshRequestAndClearsError() async throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = RetryService()
        let model = TranslationModel(
            service: service,
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults)
        )
        try installService(on: model, configuration:
            ServiceConfiguration(
                name: "Test",
                endpoint: "https://api.example.com/v1/chat/completions",
                model: "model"
            ),
            key: ""
        )
        model.updateInput("Retry me")

        model.translate()
        try await waitUntilIdle(model)
        XCTAssertEqual(model.errorMessage, "临时网络错误")
        XCTAssertEqual(model.serviceResults.first(where: { !$0.id.isBuiltIn })?.phase, .failure)

        model.translate()
        try await waitUntilIdle(model)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.serviceResults.first(where: { !$0.id.isBuiltIn })?.text, "恢复后的译文")
        XCTAssertEqual(model.serviceResults.first?.phase, .success)
        let attempts = await service.attempts
        XCTAssertEqual(attempts, 2)
    }

    func testClosingPanelCancelsRequestAndRejectsLateResponse() async throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledService()
        let model = TranslationModel(
            service: service,
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults)
        )
        try installService(on: model, configuration:
            ServiceConfiguration(
                name: "Test",
                endpoint: "https://api.example.com/v1/chat/completions",
                model: "model"
            ),
            key: ""
        )
        var didHide = false
        model.onHide = { didHide = true }
        model.updateInput("Close while loading")
        model.translate()

        model.hide()
        await service.finish("late response")
        await Task.yield()

        XCTAssertTrue(didHide)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.serviceResults.map(\.text), [""])
        XCTAssertEqual(model.serviceResults.map(\.phase), [.cancelled])
    }

    func testPermissionRecoveryButtonsUseMatchingGuide() throws {
        let defaults = try XCTUnwrap(isolatedDefaults())
        let model = TranslationModel(
            service: ControlledService(), credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults)
        )
        var permissions: [String] = []
        let authorize: (PermissionGuide.Permission) -> Void = {
            permissions.append($0 == .accessibility ? "accessibility" : "screenRecording")
        }

        model.presentSelectionError(.accessibilityPermission)
        model.performRecovery(authorize: authorize)
        model.presentScreenshotError(.permissionDenied)
        model.performRecovery(authorize: authorize)
        model.presentScreenshotError(.captureFailed)
        model.performRecovery(authorize: authorize)

        XCTAssertEqual(permissions, ["accessibility", "screenRecording"])
    }

    func testScreenshotPermissionErrorRecoversWhenRecognitionSucceeds() {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = isolatedDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = TranslationModel(
            service: ControlledService(),
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults)
        )

        model.presentScreenshotError(.permissionDenied)
        XCTAssertEqual(model.recoveryTitle, L10n.text("openScreenRecordingSettings"))

        model.prepareScreenshotText("Recovered OCR text")

        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.recoveryTitle)
        XCTAssertEqual(model.input, "Recovered OCR text")
        XCTAssertFalse(model.isLoading)
    }

    func testSelectedTextReplacesDraftWithoutStartingARequest() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = TranslationModel(
            service: ControlledService(), credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults)
        )
        model.updateInput("draft")
        model.prepareSelectedText("selected text")
        XCTAssertEqual(model.input, "selected text")
        XCTAssertTrue(model.serviceResults.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testLanguagePairPersistsAndRejectsDuplicateLanguages() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let model = TranslationModel(
            service: ControlledService(), credentials: MemoryCredentials(), settings: settings
        )

        try model.saveLanguagePair(primary: "zh-Hant", secondary: "ja")

        XCTAssertEqual(model.primaryLanguage, "zh-Hant")
        XCTAssertEqual(model.secondaryLanguage, "ja")
        XCTAssertEqual(settings.primaryLanguage, "zh-Hant")
        XCTAssertEqual(settings.secondaryLanguage, "ja")
        XCTAssertThrowsError(try model.saveLanguagePair(primary: "en", secondary: "en"))
    }

    func testSelectedChineseTextPreviewsAutomaticEnglishTarget() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = TranslationModel(
            service: ControlledService(), credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults)
        )

        model.prepareSelectedText("这是一段中文测试。")

        XCTAssertEqual(model.target, TranslationModel.automaticTarget)
        XCTAssertEqual(model.resolvedTarget, "en")
    }

    func testSuccessfulTranslationIsAddedToHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenTests.\(UUID().uuidString)", isDirectory: true)
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let history = HistoryStore(
            fileURL: directory.appendingPathComponent("history.json"),
            defaults: defaults
        )
        let model = TranslationModel(
            service: ImmediateService(response: "你好"),
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults),
            logger: NoopDiagnosticLogger(),
            history: history
        )
        try installService(on: model, configuration:
            ServiceConfiguration(
                name: "Test",
                endpoint: "https://api.example.com/v1/chat/completions",
                model: "model"
            ),
            key: ""
        )
        model.updateInput("Hello")

        model.translate()
        for _ in 0..<50 where model.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records[0].sourceText, "Hello")
        XCTAssertEqual(history.records[0].translatedText, "你好")
        XCTAssertEqual(history.records[0].targetLanguage, "zh-Hans")
    }

    func testStreamingTranslationPublishesAndCompletes() async throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = TranslationModel(
            service: ImmediateStreamingService(),
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults)
        )
        try installService(on: model, configuration:
            ServiceConfiguration(
                name: "Test",
                endpoint: "https://api.example.com/v1/chat/completions",
                model: "model"
            ),
            key: ""
        )
        model.updateInput("Hello world")

        model.translate()
        for _ in 0..<50 where model.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.serviceResults.first(where: { !$0.id.isBuiltIn })?.text, "你好世界")
        XCTAssertEqual(model.serviceResults.first?.phase, .success)
    }

    func testStreamingTranslationPublishesBeforeRequestCompletes() async throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = GatedStreamingService()
        let model = TranslationModel(
            service: service,
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults)
        )
        try installService(on: model, configuration:
            ServiceConfiguration(
                name: "Test",
                endpoint: "https://api.example.com/v1/chat/completions",
                model: "model"
            ),
            key: ""
        )
        model.updateInput("Hello world")

        model.translate()
        for _ in 0..<50 where model.serviceResults.first(where: { !$0.id.isBuiltIn })?.text != "你好" {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.serviceResults.first(where: { !$0.id.isBuiltIn })?.text, "你好")

        await service.finish()
        for _ in 0..<50 where model.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.serviceResults.first(where: { !$0.id.isBuiltIn })?.text, "你好世界")
        XCTAssertFalse(model.isLoading)
    }

    func testCancellingStreamingTranslationKeepsPublishedText() async throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = GatedStreamingService()
        let model = TranslationModel(
            service: service,
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults)
        )
        try installService(on: model, configuration:
            ServiceConfiguration(
                name: "Test",
                endpoint: "https://api.example.com/v1/chat/completions",
                model: "model"
            ),
            key: ""
        )
        model.updateInput("Hello world")
        model.translate()
        for _ in 0..<50 where model.serviceResults.first(where: { !$0.id.isBuiltIn })?.text != "你好" {
            try await Task.sleep(for: .milliseconds(10))
        }

        model.cancel()

        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.serviceResults.first(where: { !$0.id.isBuiltIn })?.text, "你好")
        XCTAssertEqual(model.serviceResults.first(where: { !$0.id.isBuiltIn })?.phase, .success)
        XCTAssertTrue(model.serviceTasks.isEmpty)
        await service.finish()
    }

    func testBuiltInDictionaryAndCustomServicePublishIndependentResults() async throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let entry = ECDictionaryEntryParser.parse(ECDictionaryRecord(
            word: "refine", phonetic: "ri'fain", definition: "v. improve",
            translation: "v. 改进", pos: "v:100", collins: 1, oxford: false,
            tag: "cet4", bnc: nil, frq: nil, exchange: "i:refining"
        ))
        let model = TranslationModel(
            service: ImmediateService(response: "完善"),
            dictionaryService: ImmediateDictionaryService(entry: entry),
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults)
        )
        try installService(on: model, configuration:
            ServiceConfiguration(
                name: "Test AI",
                endpoint: "https://api.example.com/v1/chat/completions",
                model: "model"
            ),
            key: ""
        )
        model.setServiceEnabled(.ecdict, enabled: true)
        model.updateInput("refine")

        model.translate()
        try await waitUntilIdle(model)

        XCTAssertEqual(model.serviceResults.map(\.id), [.ecdict, try XCTUnwrap(model.serviceInstances.first { !$0.provider.isBuiltIn }?.id)])
        XCTAssertEqual(model.serviceResults.map(\.phase), [.success, .success])
        XCTAssertEqual(model.serviceResults[0].dictionaryEntry?.headword, "refine")
        XCTAssertEqual(model.serviceResults[1].text, "完善")
        XCTAssertEqual(model.serviceResults.first(where: { !$0.id.isBuiltIn })?.text, "完善")
    }

    func testAppleTranslationResultCompletesThroughViewBridgeContract() async {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = isolatedDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "ecdictEnabled")
        defaults.set(false, forKey: "customServiceEnabled")
        let model = TranslationModel(
            service: ImmediateService(response: "unused"),
            dictionaryService: ImmediateDictionaryService(entry: nil),
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults), appleAvailability: MockAppleAvailability(value: .installed)
        )
        model.setSystemTranslationBridgeAvailable(true)
        model.updateInput("Hello")

        model.translate()
        await model.serviceTasks[.appleTranslation]?.value
        let request = model.appleTranslationRequest

        XCTAssertNotNil(request)
        XCTAssertEqual(request?.sourceIdentifier, "en")
        XCTAssertEqual(request?.targetIdentifier, "zh-Hans")
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.serviceResults.map(\.id), [.appleTranslation])
        model.completeAppleTranslation(request!, text: "你好")
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.serviceResults.first(where: { $0.id == .appleTranslation })?.text, "你好")
        XCTAssertEqual(model.serviceResults.first?.phase, .success)
    }

    func testAmbiguousChineseUsesConfiguredPrimaryVariantForAppleTranslation() async {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = isolatedDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "ecdictEnabled")
        defaults.set(false, forKey: "customServiceEnabled")
        let model = TranslationModel(
            service: ImmediateService(response: "unused"),
            dictionaryService: ImmediateDictionaryService(entry: nil),
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults), appleAvailability: MockAppleAvailability(value: .installed)
        )
        model.setSystemTranslationBridgeAvailable(true)
        model.updateInput("你好")

        model.translate()
        await model.serviceTasks[.appleTranslation]?.value

        XCTAssertEqual(model.appleTranslationRequest?.sourceIdentifier, "zh-Hans")
        XCTAssertEqual(model.appleTranslationRequest?.targetIdentifier, "en")
        model.cancel()
    }

    func testMissingApplePacksSkipBridgeAndOnlyPrepareAfterDownloadClick() async throws {
        for missing in [["ja"], ["ja", "zh-Hant"]] {
            let suite = "SevenTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let checker = MockAppleAvailability(value: .requiresDownload(missing))
            let model = TranslationModel(service: ImmediateService(response: "unused"), dictionaryService: ImmediateDictionaryService(entry: nil), credentials: MemoryCredentials(), settings: SettingsStore(defaults: defaults), appleAvailability: checker)
            model.setSystemTranslationBridgeAvailable(true)
            for item in model.serviceInstances where item.provider != .apple { try model.deleteService(item.id) }
            model.setSource("ja"); model.setTarget("zh-Hant"); model.updateInput("こんにちは")
            model.translate(); await model.serviceTasks[.appleTranslation]?.value
            XCTAssertNil(model.appleTranslationRequest, "缺包时不能挂载 translationTask 或调用 session.translate")
            XCTAssertEqual(model.serviceResults.first?.phase, .skipped)
            XCTAssertEqual(model.serviceResults.first?.appleMissingLanguages, missing)
            XCTAssertEqual(model.serviceResults.first?.issue, .key("downloadTheLanguagePacksToUseApple", .languages(missing)))
            XCTAssertFalse(model.isLoading)
            model.downloadAppleLanguagePacks()
            let preparation = try XCTUnwrap(model.appleTranslationRequest)
            XCTAssertTrue(preparation.prepareOnly)
            checker.value = .installed
            model.completeApplePreparation(preparation)
            await model.serviceTasks[.appleTranslation]?.value
            let translation = try XCTUnwrap(model.appleTranslationRequest)
            XCTAssertFalse(translation.prepareOnly)
            XCTAssertEqual(model.serviceResults.count, 1)
            model.completeAppleTranslation(translation, text: "你好")
            XCTAssertEqual(model.serviceResults.first?.phase, .success)
        }
    }

    func testApplePreparationRechecksPacksAndDoesNotRestartOtherCards() async throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = MockAppleAvailability(value: .requiresDownload(["ja"]))
        let model = TranslationModel(service: ImmediateService(response: "unused"), dictionaryService: ImmediateDictionaryService(entry: nil), googleService: ImmediateOnlineService(response: "Google 保留结果"), credentials: MemoryCredentials(), settings: SettingsStore(defaults: defaults), appleAvailability: checker)
        model.setSystemTranslationBridgeAvailable(true)
        _ = model.addService(.google)
        model.setServiceEnabled(.google, enabled: true)
        for item in model.serviceInstances where item.provider != .apple && item.provider != .google { try model.deleteService(item.id) }
        model.setSource("ja"); model.setTarget("zh-Hant"); model.updateInput("こんにちは")
        model.translate()
        for task in Array(model.serviceTasks.values) { await task.value }
        let before = try XCTUnwrap(model.serviceResults.first { $0.id == .google })
        model.downloadAppleLanguagePacks()
        model.completeApplePreparation(try XCTUnwrap(model.appleTranslationRequest))
        await model.serviceTasks[.appleTranslation]?.value
        XCTAssertNil(model.appleTranslationRequest, "用户未下载就点完成时不能发起翻译")
        XCTAssertEqual(model.serviceResults.first { $0.id == .appleTranslation }?.phase, .skipped)
        model.downloadAppleLanguagePacks()
        checker.value = .installed
        model.completeApplePreparation(try XCTUnwrap(model.appleTranslationRequest))
        await model.serviceTasks[.appleTranslation]?.value
        XCTAssertEqual(model.serviceResults.first { $0.id == .google }, before)
        XCTAssertFalse(try XCTUnwrap(model.appleTranslationRequest).prepareOnly)
        model.cancel()
    }

    func testSkippedAppleDownloadLanguagesSurviveRenameReorderAndDisableOtherService() async throws {
        let suite = "AppleCardListChanges.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let missing = ["ja", "zh-Hant"]
        let checker = MockAppleAvailability(value: .requiresDownload(missing))
        let model = TranslationModel(service: ImmediateService(response: "unused"), dictionaryService: ImmediateDictionaryService(entry: nil),
            googleService: ImmediateOnlineService(response: "Google result"), credentials: MemoryCredentials(), settings: SettingsStore(defaults: defaults),
            logger: NoopDiagnosticLogger(), history: HistoryStore(fileURL: folder.appendingPathComponent("history.json"), defaults: defaults), appleAvailability: checker)
        defer { model.cancel() }
        model.setSystemTranslationBridgeAvailable(true)
        _ = model.addService(.apple); _ = model.addService(.google)
        model.setServiceEnabled(.appleTranslation, enabled: true); model.setServiceEnabled(.google, enabled: true)
        for item in model.serviceInstances where item.provider != .apple && item.provider != .google { try model.deleteService(item.id) }
        model.setSource("ja"); model.setTarget("zh-Hant"); model.updateInput("こんにちは")
        model.translate()
        for task in Array(model.serviceTasks.values) { await task.value }
        let original = try XCTUnwrap(model.serviceResults.first { $0.id == .appleTranslation })
        XCTAssertEqual(original.phase, .skipped); XCTAssertEqual(original.appleMissingLanguages, missing)
        func assertDownloadAvailable(_ operation: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let card = try XCTUnwrap(model.serviceResults.first { $0.id == .appleTranslation }, file: file, line: line)
            XCTAssertEqual(card.phase, .skipped, operation, file: file, line: line)
            XCTAssertEqual(card.appleMissingLanguages, missing, operation, file: file, line: line)
            XCTAssertEqual(card.errorMessage, original.errorMessage, operation, file: file, line: line)
            XCTAssertFalse(card.appleMissingLanguages.isEmpty, "下载按钮的显示条件必须保留", file: file, line: line)
        }
        var google = try XCTUnwrap(model.instance(.google)); google.name = "Google test name"
        model.updateService(google)
        try assertDownloadAvailable("改名其他服务")
        let index = try XCTUnwrap(model.serviceInstances.firstIndex { $0.id == .google })
        model.moveServices(from: IndexSet(integer: index), to: 0)
        try assertDownloadAvailable("排序")
        model.setServiceEnabled(.google, enabled: false)
        try assertDownloadAvailable("停用其他服务")
    }

    private func makeDictionaryOnlyModel(
        dictionaryService: DictionaryServing,
        logger: DiagnosticLogging = NoopDiagnosticLogger()
    ) throws -> (TranslationModel, UserDefaults, String) {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defaults.set(true, forKey: "ecdictEnabled")
        defaults.set(false, forKey: "customServiceEnabled")
        let model = TranslationModel(
            service: ImmediateService(response: "unused"),
            dictionaryService: dictionaryService,
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults),
            logger: logger
        )
        return (model, defaults, suite)
    }

    func testDictionaryMissReportsWordNotFound() async throws {
        let (model, defaults, suite) = try makeDictionaryOnlyModel(
            dictionaryService: ImmediateDictionaryService(entry: nil)
        )
        defer { defaults.removePersistentDomain(forName: suite) }
        model.updateInput("refine")

        model.translate()
        try await waitUntilIdle(model)

        let result = try XCTUnwrap(model.serviceResults.first { $0.id == .ecdict })
        XCTAssertEqual(result.phase, .skipped, "未收录不是错误，不显示红字和重试")
        XCTAssertEqual(result.issue, .key("theOfflineDictionaryHasNoEntryFor"))
        XCTAssertNil(model.errorMessage, "跳过的结果不应顶到全局错误提示")
    }

    func testDictionaryReadFailureIsNotReportedAsWordNotFound() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = FileDiagnosticLogger(directory: directory)
        let (model, defaults, suite) = try makeDictionaryOnlyModel(
            dictionaryService: FailingDictionaryService(),
            logger: logger
        )
        defer { defaults.removePersistentDomain(forName: suite) }
        model.updateInput("refine")

        model.translate()
        try await waitUntilIdle(model)

        let result = try XCTUnwrap(model.serviceResults.first { $0.id == .ecdict })
        XCTAssertEqual(result.phase, .failure)
        XCTAssertEqual(result.issue, .key("couldNotReadTheOfflineDictionaryDelete"))

        var log = ""
        for _ in 0..<50 where !log.contains("dictionary_query_failed") {
            try await Task.sleep(nanoseconds: 10_000_000)
            log = await logger.contents()
        }
        XCTAssertTrue(log.contains("dictionary_query_failed"))
        XCTAssertTrue(log.contains("reason=database"))
        XCTAssertFalse(log.contains("malformed"), "诊断日志只记录错误类型，不记录错误说明")
        XCTAssertFalse(log.contains("refine"), "诊断日志不得记录查询词")
    }

    func testECDICTRemainsVisibleWhenInputIsNotAWord() async throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = isolatedDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let entry = ECDictionaryEntryParser.parse(ECDictionaryRecord(
            word: "refine", phonetic: "", definition: "",
            translation: "v. 改进", pos: "", collins: 0, oxford: false,
            tag: "", bnc: nil, frq: nil, exchange: ""
        ))
        let model = TranslationModel(
            service: ImmediateService(response: "Hello"),
            dictionaryService: ImmediateDictionaryService(entry: entry),
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults)
        )
        try installService(on: model, configuration:
            ServiceConfiguration(
                name: "Test", endpoint: "https://api.example.com/v1/chat/completions",
                model: "model"
            ),
            key: ""
        )
        model.setServiceEnabled(.ecdict, enabled: true)
        model.updateInput("你好")

        model.translate()
        try await waitUntilIdle(model)

        XCTAssertEqual(model.serviceResults.map(\.id), [.ecdict, try XCTUnwrap(model.serviceInstances.first { !$0.provider.isBuiltIn }?.id)])
        XCTAssertEqual(model.serviceResults.map(\.phase), [.skipped, .success])
        XCTAssertEqual(model.serviceResults[0].issue, TranslationModel.dictionaryInputIssue)
    }

    func testServiceTogglesPersistImmediately() {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = isolatedDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let model = TranslationModel(
            service: ImmediateService(response: "unused"),
            dictionaryService: ImmediateDictionaryService(entry: nil),
            credentials: MemoryCredentials(),
            settings: settings
        )

        XCTAssertTrue(model.youdaoShowsPronunciations)
        XCTAssertTrue(model.youdaoShowsDefinitions)
        XCTAssertFalse(model.youdaoShowsPhrases)
        XCTAssertFalse(model.youdaoShowsExamples)

        model.setServiceEnabled(.appleTranslation, enabled: false)
        model.setServiceEnabled(.ecdict, enabled: false)
        model.setServiceEnabled(.youdao, enabled: true)
        model.youdaoShowsPronunciations = false
        model.youdaoShowsDefinitions = false
        model.youdaoShowsPhrases = true
        model.youdaoShowsExamples = true
        model.setServiceEnabled(.google, enabled: true)
        let customID = model.addService(.custom)
        model.setServiceEnabled(customID, enabled: true)

        XCTAssertFalse(settings.serviceInstances?.first { $0.provider == .apple }?.enabled ?? true)
        XCTAssertFalse(settings.serviceInstances?.first { $0.provider == .dictionary }?.enabled ?? true)
        XCTAssertTrue(settings.serviceInstances?.first { $0.provider == .youdao }?.enabled ?? false)
        XCTAssertFalse(settings.youdaoShowsPronunciations)
        XCTAssertFalse(settings.youdaoShowsDefinitions)
        XCTAssertTrue(settings.youdaoShowsPhrases)
        XCTAssertTrue(settings.youdaoShowsExamples)
        XCTAssertTrue(settings.serviceInstances?.first { $0.provider == .google }?.enabled ?? false)
        XCTAssertTrue(settings.serviceInstances?.first { $0.id == customID }?.enabled ?? false)
    }

    func testClickingDictionaryTermStartsANewTranslation() async throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "appleTranslationEnabled")
        defaults.set(true, forKey: "youdaoEnabled")
        let model = TranslationModel(
            service: ImmediateService(response: "unused"),
            dictionaryService: ImmediateDictionaryService(entry: nil),
            youdaoService: ImmediateOnlineService(response: "创建表"),
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults)
        )
        model.updateInput("create")

        model.translateTerm("  CREATE TABLE  ")
        try await waitUntilIdle(model)

        XCTAssertEqual(model.input, "CREATE TABLE")
        XCTAssertEqual(model.serviceResults.map(\.id), [.youdao])
        XCTAssertEqual(model.serviceResults.first(where: { $0.id == .youdao })?.text, "创建表")
        XCTAssertEqual(model.serviceResults.first?.phase, .success)
    }

    func testTwoKeyServiceInstancesRunIndependently() async throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = TranslationModel(
            service: ImmediateService(response: "译文"),
            dictionaryService: ImmediateDictionaryService(entry: nil),
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults)
        )
        try installService(on: model, configuration:
            ServiceConfiguration(
                name: "DeepSeek",
                endpoint: "https://api.deepseek.com/chat/completions",
                model: "deepseek-chat"
            ),
            key: "test-key"
        )
        let second = model.addService(.zhipu)
        try model.saveServiceKey(second, key: "test-key-2")
        model.updateInput("Hello")

        model.translate()
        try await waitUntilIdle(model)

        XCTAssertEqual(model.serviceResults.map(\.id), [try XCTUnwrap(model.serviceInstances.first { !$0.provider.isBuiltIn }?.id), second])
        XCTAssertEqual(model.serviceResults.map(\.phase), [.success, .success])
    }

    func testYoudaoAndGooglePublishIndependentResults() async throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "appleTranslationEnabled")
        defaults.set(false, forKey: "customServiceEnabled")
        defaults.set(true, forKey: "youdaoEnabled")
        defaults.set(true, forKey: "googleEnabled")
        let model = TranslationModel(
            service: ImmediateService(response: "unused"),
            dictionaryService: ImmediateDictionaryService(entry: nil),
            youdaoService: ImmediateOnlineService(response: "有道结果"),
            googleService: ImmediateOnlineService(response: "Google 结果"),
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults)
        )
        model.updateInput("Hello")

        model.translate()
        try await waitUntilIdle(model)

        XCTAssertEqual(model.serviceResults.map(\.id), [.youdao, .google])
        XCTAssertEqual(model.serviceResults.map(\.phase), [.success, .success])
        XCTAssertEqual(model.serviceResults.map(\.text), ["有道结果", "Google 结果"])
    }

    func testExpandingOneServiceWithoutResultsOnlyStartsThatService() async throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "zhipuFreeEnabled")
        defaults.set(false, forKey: "appleTranslationEnabled")
        defaults.set(false, forKey: "ecdictEnabled")
        defaults.set(false, forKey: "customServiceEnabled")
        defaults.set(true, forKey: "youdaoEnabled")
        defaults.set(true, forKey: "googleEnabled")
        let settings = SettingsStore(defaults: defaults)
        settings.setServiceExpanded(false, provider: .youdao)
        settings.setServiceExpanded(true, provider: .google)
        let youdao = CountingOnlineService(response: "有道结果")
        let google = CountingOnlineService(response: "Google 结果")
        let model = TranslationModel(
            service: ImmediateService(response: "unused"),
            dictionaryService: ImmediateDictionaryService(entry: nil),
            youdaoService: youdao,
            googleService: google,
            credentials: MemoryCredentials(),
            settings: settings
        )
        model.updateInput("Hello")

        model.setServiceExpanded(.youdao, expanded: true)
        try await waitUntilIdle(model)

        let youdaoAttempts = await youdao.attempts
        let googleAttempts = await google.attempts
        XCTAssertEqual(youdaoAttempts, 1)
        XCTAssertEqual(googleAttempts, 0)
        XCTAssertEqual(model.serviceResults.first(where: { $0.id == .youdao })?.text, "有道结果")
        XCTAssertEqual(model.serviceResults.first(where: { $0.id == .google })?.phase, .idle)
    }

    func testClearTransitionRetainsResultsUntilAnimationFinishes() async throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "appleTranslationEnabled")
        defaults.set(false, forKey: "customServiceEnabled")
        defaults.set(true, forKey: "googleEnabled")
        let model = TranslationModel(
            service: ImmediateService(response: "unused"),
            dictionaryService: ImmediateDictionaryService(entry: nil),
            googleService: ImmediateOnlineService(response: "Google 结果"),
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults)
        )
        model.updateInput("Hello")
        model.translate()
        try await waitUntilIdle(model)

        model.beginClearTransition()

        XCTAssertTrue(model.input.isEmpty)
        XCTAssertEqual(model.serviceResults.first?.text, "Google 结果")

        model.finishClearTransition()
        XCTAssertTrue(model.serviceResults.isEmpty)
    }

    func testRetryingOneServicePreservesOtherServiceResults() async throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "appleTranslationEnabled")
        defaults.set(false, forKey: "customServiceEnabled")
        defaults.set(true, forKey: "youdaoEnabled")
        defaults.set(true, forKey: "googleEnabled")
        let youdao = FailOnceOnlineService()
        let model = TranslationModel(
            service: ImmediateService(response: "unused"),
            dictionaryService: ImmediateDictionaryService(entry: nil),
            youdaoService: youdao,
            googleService: ImmediateOnlineService(response: "Google 保留结果"),
            credentials: MemoryCredentials(),
            settings: SettingsStore(defaults: defaults)
        )
        model.updateInput("Hello")
        model.translate()
        try await waitUntilIdle(model)

        XCTAssertEqual(model.serviceResults.first(where: { $0.id == .youdao })?.phase, .failure)
        XCTAssertEqual(model.serviceResults.first(where: { $0.id == .google })?.text, "Google 保留结果")

        model.retryResult(.youdao)
        try await waitUntilIdle(model)

        XCTAssertEqual(model.serviceResults.first(where: { $0.id == .youdao })?.text, "有道恢复结果")
        XCTAssertEqual(model.serviceResults.first(where: { $0.id == .google })?.text, "Google 保留结果")
        let attempts = await youdao.attempts
        XCTAssertEqual(attempts, 2)
    }

    func testCollapseFinishesCurrentRequestButSkipsFutureRequestsUntilExpanded() async throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "appleTranslationEnabled")
        defaults.set(false, forKey: "customServiceEnabled")
        defaults.set(true, forKey: "youdaoEnabled")
        let settings = SettingsStore(defaults: defaults)
        let youdao = GatedOnlineService()
        let model = TranslationModel(
            service: ImmediateService(response: "unused"),
            dictionaryService: ImmediateDictionaryService(entry: nil),
            youdaoService: youdao,
            credentials: MemoryCredentials(),
            settings: settings
        )
        model.updateInput("Hello")

        model.updateInput("第一次")
        model.translate()
        await Task.yield()
        model.setServiceExpanded(.youdao, expanded: false)
        await youdao.finishFirstRequest()
        try await waitUntilIdle(model)

        XCTAssertFalse(model.isServiceExpanded(.youdao))
        XCTAssertEqual(model.serviceResults.first?.text, "后台结果 1")
        let attemptsAfterCollapse = await youdao.attempts
        XCTAssertEqual(attemptsAfterCollapse, 1)

        model.updateInput("第二次")
        model.translate()

        XCTAssertEqual(model.serviceResults.first?.phase, .skipped)
        let attemptsWhileCollapsed = await youdao.attempts
        XCTAssertEqual(attemptsWhileCollapsed, 1)

        model.setServiceExpanded(.youdao, expanded: true)
        try await waitUntilIdle(model)

        XCTAssertEqual(model.serviceResults.first?.text, "后台结果 2")
        XCTAssertTrue(settings.isServiceExpanded(.youdao))
        let attemptsAfterExpansion = await youdao.attempts
        XCTAssertEqual(attemptsAfterExpansion, 2)
    }
}

@MainActor private final class MockAppleAvailability: AppleTranslationAvailabilityChecking {
    var value: AppleTranslationAvailability
    init(value: AppleTranslationAvailability) { self.value = value }
    func availability(source: String, target: String) async -> AppleTranslationAvailability { value }
}
