import Foundation
import XCTest
import Combine
@testable import Seven

@MainActor private final class InstanceCredentials: @preconcurrency CredentialStoring {
    var values: [String: String] = [:]
    var failSave = false
    var failRead = false
    var reads = 0
    var writes = 0
    func read(account: String) throws -> String {
        reads += 1
        if failRead { throw TranslationError.configuration("mock read failure") }
        return values[account, default: ""]
    }
    func save(_ value: String, account: String) throws {
        writes += 1
        if failSave { throw TranslationError.configuration("mock failure") }
        values[account] = value
    }
}
private actor InstanceService: TranslationServing {
    private(set) var requests: [TranslationRequest] = []
    func translateStream(_ request: TranslationRequest, onUpdate: @escaping @Sendable (String) async -> Void) async throws -> String {
        requests.append(request)
        return request.configuration.name + ":" + request.apiKey
    }
}

private struct EchoingFailureService: TranslationServing {
    func translateStream(_ request: TranslationRequest, onUpdate: @escaping @Sendable (String) async -> Void) async throws -> String {
        throw TranslationError.transport(.verbatim(request.text + request.apiKey))
    }
}
private actor InstanceLogger: DiagnosticLogging {
    nonisolated let fileURL = URL(fileURLWithPath: "/dev/null")
    private(set) var entries: [(String, [String:String])] = []
    func record(_ level: DiagnosticLevel, _ event: String, metadata: [String:String]) { entries.append((event,metadata)) }
    func contents() -> String { entries.map { $0.0 + $0.1.values.joined() }.joined() }
    func clear() { entries=[] }
}

private struct ChatEndpointTester: ServiceConfigurationTesting {
    func test(configuration: ServiceConfiguration, apiKey: String, firstLanguage: String) async throws -> ServiceConfigurationTestResult {
        ServiceConfigurationTestResult(elapsed: 0, apiStyle: .openAICompatible)
    }
}

final class ServiceInstanceTests: XCTestCase {
    @MainActor func testSystemBridgeNotificationExposesUpdatedAvailability() throws {
        let (_, settings) = try store()
        settings.serviceInstances = [.init(provider: .apple)]
        let model = TranslationModel(credentials: InstanceCredentials(), settings: settings)
        var snapshots: [Bool] = []
        let subscription = model.objectWillChange.sink {
            snapshots.append(model.displayedServiceResults.contains { $0.id == .appleTranslation })
        }
        defer { subscription.cancel() }
        model.setSystemTranslationBridgeAvailable(true)
        XCTAssertEqual(snapshots, [true], "通知求值时不能仍把已可用的 Apple 翻译过滤掉")
    }

    private func store() throws -> (UserDefaults, SettingsStore) {
        let d = try XCTUnwrap(isolatedDefaults(suiteName: "ServiceInstances-" + UUID().uuidString))
        let settings = SettingsStore(defaults: d)
        settings.languageDetectionMode = .system
        return (d, settings)
    }
    func testSavedInstancesWithoutPromptKeepTheirIdentityAndCredentialAccount() throws {
        let (defaults, settings) = try store()
        var item = ServiceInstance(provider: .custom, name: "Configured", enabled: false)
        item.mode = .custom
        item.baseAddress = "https://api.example.com/v1"
        let encoded = try JSONEncoder().encode(item)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        fields.removeValue(forKey: "prompt")
        defaults.set(try JSONSerialization.data(withJSONObject: [fields]), forKey: "serviceInstances.v2")

        let restored = try XCTUnwrap(settings.migrateServiceInstances().first)
        XCTAssertEqual(restored, item)
        XCTAssertEqual(restored.configuration.credentialAccount, item.configuration.credentialAccount)
    }

    func testFreshInstallEnablesBuiltInTranslatorsAndLeavesDictionaryOff() throws {
        let (_, settings) = try store()
        XCTAssertNil(settings.serviceInstances)

        let services = settings.migrateServiceInstances()

        XCTAssertEqual(services.map(\.provider), [.dictionary, .apple, .youdao, .google])
        XCTAssertEqual(services.filter(\.enabled).map(\.provider), [.apple, .youdao, .google])
        XCTAssertEqual(settings.serviceInstances, services)
    }

    func testSavedServiceListPreservesDisabledOnlineProvidersAndOrder() throws {
        let (_, settings) = try store()
        let saved: [ServiceInstance] = [
            .init(provider: .google, enabled: false),
            .init(provider: .apple, enabled: true),
            .init(provider: .youdao, enabled: false)
        ]
        settings.serviceInstances = saved
        settings.googleEnabled = true
        settings.youdaoEnabled = true

        XCTAssertEqual(settings.migrateServiceInstances(), saved)
        XCTAssertEqual(settings.serviceInstances, saved)
    }

    func testPartialLegacyPreferencesRetainOriginalServiceDefaults() throws {
        let (_, settings) = try store()
        settings.youdaoEnabled = true
        settings.appleTranslationEnabled = false

        let services = settings.migrateServiceInstances()

        XCTAssertEqual(services.filter(\.enabled).map(\.provider), [.youdao])
        XCTAssertEqual(settings.serviceInstances, services)
    }

    @MainActor func testConfigurationMigrationPreservesSettingsWithoutAccessingKeys() throws {
        let (d, s) = try store(); let keys = InstanceCredentials()
        s.appleTranslationEnabled=false; s.youdaoEnabled=true; s.googleEnabled=true; s.ecdictEnabled=true
        s.configured=true; s.customServiceEnabled=false
        let legacy = """
        {
          "name": "Old",
          "endpoint": "https://proxy.example.com/v1/messages",
          "model": "claude-example",
          "mode": "translate",
          "systemPrompt": "用户保存的系统提示词",
          "userPrompt": "{{text}}",
          "timeoutSeconds": 60,
          "apiStyle": "anthropic"
        }
        """
        d.set(Data(legacy.utf8), forKey: "serviceConfiguration.v1")
        let config = s.configuration
        keys.values[config.credentialAccount] = "old-key"
        d.set(true,forKey:"zhipuFreeEnabled")
        keys.failSave = true
        let model = TranslationModel(credentials: keys, settings: s)
        XCTAssertEqual(s.serviceInstances, model.serviceInstances)
        let items = model.serviceInstances
        let migrated=try XCTUnwrap(items.last)
        XCTAssertEqual(items.map(\.provider),[.dictionary,.apple,.youdao,.google,.custom])
        XCTAssertEqual(items.map(\.enabled),[true,false,true,true,false])
        XCTAssertEqual(migrated.id,.compatible)
        XCTAssertEqual(migrated.configuration.endpoint, "https://proxy.example.com/v1/messages")
        XCTAssertTrue(migrated.prompt.isEmpty)
        XCTAssertNil(keys.values[migrated.configuration.credentialAccount]); XCTAssertEqual(keys.reads,0); XCTAssertEqual(keys.writes,0)
        XCTAssertEqual(keys.values[config.credentialAccount],"old-key")
        XCTAssertFalse(String(decoding:try XCTUnwrap(d.data(forKey:"serviceInstances.v2")),as:UTF8.self).contains("old-key"))
    }
    func testMigrationIsIdempotentAfterEditingAndDeletingEverything() throws {
        let (_,s)=try store()
        let first=s.migrateServiceInstances()
        XCTAssertEqual(s.migrateServiceInstances(),first)
        s.serviceInstances=[];s.configured=true
        XCTAssertTrue(s.migrateServiceInstances().isEmpty)
        XCTAssertEqual(s.serviceInstances, [])
    }
    func testCorruptOrDuplicateV2IsRepaired() throws {
        let (d,s)=try store()
        let corrupt=Data("not-json".utf8);d.set(corrupt,forKey:"serviceInstances.v2")
        XCTAssertTrue(s.migrateServiceInstances().isEmpty)
        s.serviceInstances=[.init(provider:.google),.init(provider:.google)]
        XCTAssertEqual(s.migrateServiceInstances().map(\.provider), [.google])
    }
    @MainActor func testInvalidServiceEntryDoesNotDiscardValidInstancesOrPreventAdding() throws {
        let (d, settings) = try store()
        let valid = ServiceInstance(provider: .openAI)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
        let wrongID = ServiceInstance(provider: .google, id: TranslationProviderID(rawValue: "wrong-id"))
        let wrong = try JSONSerialization.jsonObject(with: JSONEncoder().encode(wrongID))
        d.set(try JSONSerialization.data(withJSONObject: [json, ["provider": "removed-provider"], wrong, wrong]), forKey: "serviceInstances.v2")
        let repaired = settings.migrateServiceInstances()
        XCTAssertEqual(repaired.map(\.id), [valid.id, .google])
        XCTAssertEqual(settings.migrateServiceInstances(), repaired)
        let model = TranslationModel(credentials: InstanceCredentials(), settings: settings)
        XCTAssertEqual(settings.serviceInstances, model.serviceInstances)
        let added = model.addService(.deepSeek)
        XCTAssertNotNil(model.instance(added))
    }
    func testEveryStyleNormalizesCompletePathAndBuildsOneSuffix() throws {
        for (style,suffix) in [(ServiceAPIStyle.openAICompatible,"/chat/completions"),(.openAIResponses,"/responses"),(.anthropic,"/messages"),(.gemini,"/models/model:generateContent")] {
            let full="https://gateway.example.com/prefix/v1"+suffix
            XCTAssertEqual(ServiceEndpoint.normalizedBase(full+"/"),"https://gateway.example.com/prefix/v1")
            XCTAssertEqual(ServiceEndpoint.requestAddress(base:full,style:style,model:"model"),full)
        }
        XCTAssertEqual(ServiceEndpoint.normalizedBase("https://example.com/v1beta/models/m:streamGenerateContent?alt=sse"),"https://example.com/v1beta")
        XCTAssertEqual(ServiceEndpoint.pastedBase("https://example.com/v1/messages"),"https://example.com/v1")
        XCTAssertNil(ServiceEndpoint.pastedBase("https://example.com/v1/"))
    }
    @MainActor func testDuplicateBuiltInIsSingletonAndCanBeAddedBack() throws {
        let (_,s)=try store();let m=TranslationModel(credentials:InstanceCredentials(),settings:s)
        let id=m.addService(.dictionary)
        XCTAssertEqual(m.serviceInstances.filter { $0.provider == .dictionary }.count,1)
        try m.deleteService(id);XCTAssertFalse(m.serviceInstances.contains { $0.id==id })
        XCTAssertEqual(m.addService(.dictionary),id)
    }
    @MainActor func testDeleteConfirmationOnlyAppliesToServicesWithSavedKeys() throws {
        let (_, settings) = try store()
        let model = TranslationModel(credentials: InstanceCredentials(), settings: settings)
        for provider in ServiceProvider.builtIns {
            XCTAssertFalse(model.hasSavedServiceKey(model.addService(provider)))
        }
        let id = model.addService(.openAI)
        XCTAssertFalse(model.hasSavedServiceKey(id))
        try model.saveServiceKey(id, key: "saved-key")
        XCTAssertTrue(model.hasSavedServiceKey(id))
        try model.saveServiceKey(id, key: "")
        XCTAssertFalse(model.hasSavedServiceKey(id))
    }
    @MainActor func testSameProviderInstancesHaveSeparateNamesKeysAndDeletion() throws {
        let (_,s)=try store();let keys=InstanceCredentials();let m=TranslationModel(credentials:keys,settings:s)
        let a=m.addService(.deepSeek),b=m.addService(.deepSeek)
        XCTAssertNotEqual(a,b);XCTAssertEqual(m.instance(b)?.name,"DeepSeek 2")
        try m.saveServiceKey(a,key:"one");try m.saveServiceKey(b,key:"two")
        let ac=try XCTUnwrap(m.instance(a)?.configuration.credentialAccount),bc=try XCTUnwrap(m.instance(b)?.configuration.credentialAccount)
        XCTAssertNotEqual(ac,bc);XCTAssertEqual(keys.values[ac],"one");XCTAssertEqual(keys.values[bc],"two")
        keys.failSave=true;XCTAssertThrowsError(try m.deleteService(a));XCTAssertNotNil(m.instance(a))
        keys.failSave=false;try m.deleteService(a);XCTAssertEqual(keys.values[ac],"");XCTAssertEqual(keys.values[bc],"two")
    }
    @MainActor func testDeleteConfirmationIsRequiredWhenCredentialReadFails() throws {
        let (_, settings) = try store(); let keys = InstanceCredentials()
        let model = TranslationModel(credentials: keys, settings: settings)
        let id = model.addService(.openAI)
        XCTAssertFalse(model.hasSavedServiceKey(id))
        keys.failRead = true
        XCTAssertTrue(model.hasSavedServiceKey(id))
        XCTAssertFalse(model.hasSavedServiceKey(.google))
    }
    @MainActor func testRenameAndAddressChangesDoNotMoveCredentialAccount() throws {
        let (_,s)=try store();let keys=InstanceCredentials();let m=TranslationModel(credentials:keys,settings:s)
        let a=m.addService(.custom);let b=m.addService(.custom)
        try m.saveServiceKey(a,key:"one");let before=try XCTUnwrap(m.instance(a)?.configuration.credentialAccount)
        var item=try XCTUnwrap(m.instance(a));item.name="自定义 2";item.baseAddress="https://proxy.example.com/v1/responses";item.apiStyle = .openAIResponses
        m.updateService(item)
        XCTAssertNotEqual(m.instance(a)?.name,m.instance(b)?.name)
        XCTAssertEqual(m.instance(a)?.configuration.credentialAccount,before);XCTAssertEqual(keys.values[before],"one")
        XCTAssertEqual(m.instance(a)?.baseAddress,"https://proxy.example.com/v1")
    }
    @MainActor func testOrderedInstancesDispatchIndependentlyAndReorderCards() async throws {
        let (_,s)=try store();let keys=InstanceCredentials();let service=InstanceService()
        s.serviceInstances = []
        s.primaryLanguage = "fr"
        let m=TranslationModel(service:service,credentials:keys,settings:s)
        let a=m.addService(.deepSeek),b=m.addService(.deepSeek)
        try m.saveServiceKey(a,key:"one");try m.saveServiceKey(b,key:"two")
        m.updateInput("hello");m.translate()
        for _ in 0..<100 where m.isLoading { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(m.serviceResults.map(\.id),[a,b]);XCTAssertEqual(m.serviceResults.map(\.text),["DeepSeek:one","DeepSeek 2:two"])
        let requests=await service.requests;XCTAssertEqual(Set(requests.map(\.apiKey)),["one","two"])
        XCTAssertEqual(Set(requests.map(\.firstLanguage)), ["fr"])
        m.moveServices(from:IndexSet(integer:m.serviceInstances.count-1),to:0)
        XCTAssertEqual(m.serviceResults.map(\.id),[b,a]);XCTAssertEqual(s.serviceInstances?.first?.id,b)
    }
    @MainActor func testPresetWithoutKeyDoesNotSendNetworkRequest() async throws {
        let (_,s)=try store();let service=InstanceService()
        s.serviceInstances = []
        let m=TranslationModel(service:service,credentials:InstanceCredentials(),settings:s)
        let id=m.addService(.deepSeek);m.updateInput("hello");m.translate()
        for _ in 0..<100 where m.isLoading { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(m.serviceResults.first { $0.id==id }?.phase,.failure)
        let count=await service.requests.count;XCTAssertEqual(count,0)
    }
    @MainActor func testServiceLogsDoNotIncludeServerEchoOrPromptOrKey() async throws {
        let (_,s)=try store();let logger=InstanceLogger()
        s.serviceInstances = []
        let m=TranslationModel(service:EchoingFailureService(),credentials:InstanceCredentials(),settings:s,logger:logger)
        let id=m.addService(.deepSeek);try m.saveServiceKey(id,key:"PRIVATE-KEY")
        m.updateInput("PRIVATE-SOURCE");m.translate()
        for _ in 0..<100 {
            if await logger.contents().contains("translation_failed") { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        let log=await logger.contents();XCTAssertTrue(log.contains("translation_failed"))
        XCTAssertFalse(log.contains("PRIVATE-KEY"));XCTAssertFalse(log.contains("PRIVATE-SOURCE"))
        let entries=await logger.entries
        for (_,fields) in entries { XCTAssertTrue(Set(fields.keys).isSubset(of:["host","elapsed_ms","characters","reason"])) }
    }
    @MainActor func testVerifiedEndpointIsSavedUsedAndInvalidatedOnlyByConnectionChanges() async throws {
        let (_, settings) = try store(); let service = InstanceService()
        settings.serviceInstances = []
        let model = TranslationModel(service: service, credentials: InstanceCredentials(), settings: settings, configurationTester: ChatEndpointTester())
        let id = model.addService(.openAI); try model.saveServiceKey(id, key: "mock-key")
        let initial = try XCTUnwrap(model.instance(id))
        model.testConfiguration(initial.configuration, key: "mock-key")
        for _ in 0..<100 where model.isTestingConfiguration { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.configurationTestSucceeded)
        XCTAssertEqual(model.instance(id)?.detectedAPIStyle, .openAICompatible)
        XCTAssertEqual(settings.serviceInstances?.first { $0.id == id }?.detectedAPIStyle, .openAICompatible)
        model.updateInput("hello"); model.translate()
        for _ in 0..<100 where model.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        let requests = await service.requests
        XCTAssertEqual(requests.first?.configuration.apiStyle, .openAICompatible)
        var staleDraft = initial; staleDraft.name = "Renamed"
        model.updateService(staleDraft)
        XCTAssertEqual(model.instance(id)?.detectedAPIStyle, .openAICompatible, "编辑旧草稿不能覆盖已识别格式")
        staleDraft.baseAddress = "https://proxy.example.com/v1"; model.updateService(staleDraft)
        XCTAssertNil(model.instance(id)?.detectedAPIStyle)
        model.rememberVerifiedAPIStyle(.openAICompatible, configuration: initial.configuration)
        XCTAssertNil(model.instance(id)?.detectedAPIStyle, "旧地址的验证不能写到新地址")
        let current = try XCTUnwrap(model.instance(id))
        model.rememberVerifiedAPIStyle(.openAICompatible, configuration: current.configuration)
        try model.saveServiceKey(id, key: "different-key")
        XCTAssertNil(model.instance(id)?.detectedAPIStyle)
        model.rememberVerifiedAPIStyle(.openAICompatible, configuration: current.configuration)
        var edited = try XCTUnwrap(model.instance(id)); edited.model = "different-model"; model.updateService(edited)
        XCTAssertNil(model.instance(id)?.detectedAPIStyle)
    }

}
