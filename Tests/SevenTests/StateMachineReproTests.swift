import AppKit
import XCTest
@testable import Seven

// 保持设置迁移、服务排序和历史配置走生产入口，偏好值只存在内存中。
final class ReproDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    override func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}

private struct ReproCredentials: CredentialStoring {
    func read(account: String) throws -> String { "" }
    func save(_ value: String, account: String) throws {}
}

private struct ReproAppleAvailability: AppleTranslationAvailabilityChecking {
    func availability(source: String, target: String) async -> AppleTranslationAvailability {
        .requiresDownload(["zh-Hans"])
    }
}

struct ReproService: TranslationServing {
    var run: @Sendable (TranslationRequest, @escaping @Sendable (String) async -> Void) async throws -> String

    func translateStream(
        _ request: TranslationRequest, onUpdate: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        try await run(request, onUpdate)
    }

    static let immediate = Self { _, _ in "完整译文" }
}

@MainActor
final class ReproGate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    // 同一个开关只暂停第一次调用；重试可以照常运行。
    func pause() async {
        guard !entered else { return }
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class StateMachineReproTests: XCTestCase {
    func reached(_ description: String, until condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let satisfied = condition()
        _ = try XCTUnwrap(satisfied ? true : nil, "未满足测试前置条件：\(description)")
    }

    func temporaryDirectory() throws -> URL {
        let directory = URL(filePath: "/tmp", directoryHint: .isDirectory)
            .appending(path: "seven-repro-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    func model(
        service: ReproService = .immediate,
        history: HistoryStore? = nil,
        logger: DiagnosticLogging = NoopDiagnosticLogger()
    ) throws -> TranslationModel {
        let settings = SettingsStore(defaults: ReproDefaults())
        settings.languageDetectionMode = .system
        settings.speechEngine = .system
        let model = TranslationModel(
            service: service, credentials: ReproCredentials(), settings: settings, logger: logger,
            history: history, speech: SpeechController(settings: settings, systemVoiceLanguages: { ["zh-CN"] }),
            languageDetectors: [:], appleAvailability: ReproAppleAvailability()
        )
        for item in model.serviceInstances {
            try model.deleteService(item.id)
        }
        model.setSource("en")
        model.setTarget("zh-Hans")
        return model
    }

    @discardableResult
    func addService(_ name: String, to model: TranslationModel) throws -> TranslationProviderID {
        let id = model.addService(.custom)
        var item = try XCTUnwrap(model.instance(id))
        item.apply(ServiceConfiguration(
            name: name, endpoint: "https://example.invalid/v1/chat/completions", model: name, mode: .translate
        ))
        item.enabled = true
        model.updateService(item)
        return id
    }

    private func makeHistory() throws -> HistoryStore {
        let history = HistoryStore(
            fileURL: try temporaryDirectory().appending(path: "history.json"), defaults: ReproDefaults()
        )
        history.isEnabled = true
        return history
    }

    func testRepro02_cancelledStreamCanBeUsedToSwapLanguages() async throws {
        let gate = ReproGate()
        defer { gate.release() }
        let model = try model(service: ReproService { _, update in
            await update("截断译文")
            await gate.pause()
            return "完整译文"
        })
        let provider = try addService("A", to: model)
        model.updateInput("Hello world")
        model.translate()
        let task = try XCTUnwrap(model.serviceTasks[provider])
        try await reached("片段已发布且流仍在进行", until: { gate.entered })
        XCTAssertEqual(model.serviceResults.first?.text, "截断译文")

        model.hide()
        gate.release()
        await task.value

        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.serviceResults.first?.text, "截断译文")
        model.swapLanguages()
        XCTAssertEqual(model.input, "截断译文")
        await model.serviceTasks[provider]?.value
    }

    func testRepro02_retryFailureDoesNotSaveAnotherCancelledStream() async throws {
        let first = ReproGate(), second = ReproGate()
        defer { first.release(); second.release() }
        let history = try makeHistory()
        let model = try model(service: ReproService { request, update in
            if request.configuration.model == "A" {
                await first.pause()
                throw TranslationError.transport("模拟网络中断")
            }
            await update("截断译文")
            await second.pause()
            return "完整译文"
        }, history: history)
        let a = try addService("A", to: model)
        let b = try addService("B", to: model)
        model.updateInput("Hello world")
        model.translate()
        let firstTask = try XCTUnwrap(model.serviceTasks[a])
        let secondTask = try XCTUnwrap(model.serviceTasks[b])
        try await reached("两路请求均未完成，B 先输出片段", until: { first.entered && second.entered })
        XCTAssertEqual(model.primaryResultID, a)
        XCTAssertTrue(history.records.isEmpty)
        model.hide()
        first.release()
        second.release()
        await firstTask.value
        await secondTask.value

        model.retryResult(a)
        await (try XCTUnwrap(model.serviceTasks[a])).value

        XCTAssertEqual(model.serviceResults.first?.phase, .failure)
        XCTAssertEqual(history.records.flatMap(\.results).map(\.translatedText), [])
    }

    func testRepro03_failedPartialResultKeepsCopyAndSpeechAvailable() async throws {
        _ = NSApplication.shared
        let model = try model(service: ReproService { _, update in
            await update("未完成的译文")
            throw TranslationError.transport("模拟网络中断")
        })
        let provider = try addService("A", to: model)
        model.updateInput("Hello world")
        model.translate()
        await (try XCTUnwrap(model.serviceTasks[provider])).value
        let result = try XCTUnwrap(model.serviceResults.first)
        XCTAssertEqual(result.phase, .failure)
        XCTAssertEqual(result.text, "未完成的译文")
        XCTAssertTrue(model.speech.canSpeak(text: "未完成的译文", declaredLanguage: "zh-Hans"))

        let card = AppKitServiceCardView(model: model, provider: provider)
        card.apply(result, hasCurrentResult: true, suppressBody: false, animated: false)
        let buttons = descendants(card).compactMap { $0 as? NSButton }
        let copy = try XCTUnwrap(buttons.first { $0.action == NSSelectorFromString("copyResult") })
        let speech = try XCTUnwrap(buttons.first { $0 is SpeechToggleButton })
        XCTAssertTrue(copy.isEnabled)
        XCTAssertTrue(speech.isEnabled)
    }

    func testRepro21_remainingSuccessfulServiceIsSavedAfterDisablingPreferredService() async throws {
        let first = ReproGate(), second = ReproGate()
        defer { first.release(); second.release() }
        let history = try makeHistory()
        let model = try model(service: ReproService { request, _ in
            if request.configuration.model == "A" {
                await first.pause()
                return "A 的完整译文"
            }
            await second.pause()
            return "B 的完整译文"
        }, history: history)
        let a = try addService("A", to: model)
        let b = try addService("B", to: model)
        model.updateInput("Hello world")
        model.translate()
        let firstTask = try XCTUnwrap(model.serviceTasks[a])
        let secondTask = try XCTUnwrap(model.serviceTasks[b])
        try await reached("首选 A 和备用 B 同时在途", until: { first.entered && second.entered })
        XCTAssertEqual(model.primaryResultID, a)

        model.setServiceEnabled(a, enabled: false)
        first.release()
        second.release()
        await firstTask.value
        await secondTask.value

        XCTAssertEqual(model.serviceResults.map(\.id), [b])
        XCTAssertEqual(model.serviceResults.first?.phase, .success)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(history.records.flatMap(\.results).map(\.translatedText), ["B 的完整译文"])
    }

    func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
