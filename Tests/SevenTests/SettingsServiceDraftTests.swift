import AppKit
import SwiftUI
import XCTest
@testable import Seven

@MainActor private final class DraftCredentials: @preconcurrency CredentialStoring {
    var values: [String: String] = [:]
    var writes = 0
    var failSave = false
    var failRead = false
    func read(account: String) throws -> String {
        if failRead { throw TranslationError.configuration("mock read failure") }
        return values[account, default: ""]
    }
    func save(_ value: String, account: String) throws {
        if failSave { throw TranslationError.configuration("mock save failure") }
        writes += 1; values[account] = value
    }
}

private actor DraftConfigurationTester: ServiceConfigurationTesting {
    private(set) var received: [(ServiceConfiguration, String)] = []
    func test(configuration: ServiceConfiguration, apiKey: String, firstLanguage: String) async throws -> ServiceConfigurationTestResult {
        received.append((configuration, apiKey))
        return ServiceConfigurationTestResult(elapsed: 0, apiStyle: .openAICompatible)
    }
}

@MainActor final class SettingsServiceDraftTests: XCTestCase {
    private func fixture() throws -> (TranslationModel, SettingsStore, DraftCredentials, SettingsServiceDraft, DraftConfigurationTester) {
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: "ServiceDraft-" + UUID().uuidString))
        let settings = SettingsStore(defaults: defaults)
        var item = ServiceInstance(provider: .openAI)
        item.fetchedModels = ["cached-a", "cached-b"]
        settings.serviceInstances = [item]
        let keys = DraftCredentials()
        keys.values[item.configuration.credentialAccount] = "saved-key"
        let tester = DraftConfigurationTester()
        let model = TranslationModel(credentials: keys, settings: settings, configurationTester: tester)
        let editor = SettingsServiceDraft()
        try editor.load(item, using: model)
        return (model, settings, keys, editor, tester)
    }

    func testEditsRemainDraftUntilExplicitSaveAndPreserveLiveEnabledState() throws {
        let (model, settings, keys, editor, _) = try fixture()
        let original = try XCTUnwrap(model.instance(editor.value.id))
        XCTAssertFalse(editor.hasChanges)
        editor.value.name = "新服务名称"
        editor.value.baseAddress = "https://draft.example/v1"
        editor.value.model = "draft-model"
        editor.value.timeoutSeconds = 120
        editor.value.systemPrompt = "合成系统提示"
        editor.value.userPrompt = "合成用户提示 {{text}}"
        editor.value.manualModels = ["manual-model"]
        editor.apiKey = "  draft-key  "
        editor.value.fetchedModels = ["draft-model"]
        XCTAssertTrue(editor.hasChanges)
        XCTAssertEqual(model.instance(original.id), original)
        XCTAssertEqual(settings.serviceInstances, [original])
        XCTAssertEqual(keys.writes, 0)
        XCTAssertEqual(keys.values[original.configuration.credentialAccount], "saved-key")
        model.setServiceEnabled(original.id, enabled: false)
        try editor.save(using: model)
        let saved = try XCTUnwrap(model.instance(original.id))
        XCTAssertEqual(saved.name, "新服务名称")
        XCTAssertEqual(saved.model, "draft-model")
        XCTAssertEqual(saved.systemPrompt, "合成系统提示")
        XCTAssertEqual(saved.userPrompt, "合成用户提示 {{text}}")
        XCTAssertEqual(saved.timeoutSeconds, 120)
        XCTAssertEqual(saved.manualModels, ["manual-model"])
        XCTAssertEqual(saved.fetchedModels, ["draft-model"])
        XCTAssertFalse(saved.enabled, "保存详情不能覆盖即时生效的列表勾选")
        XCTAssertEqual(settings.serviceInstances, [saved])
        XCTAssertEqual(keys.values[original.configuration.credentialAccount], "draft-key")
        XCTAssertEqual(keys.writes, 1)
        XCTAssertFalse(editor.hasChanges)
        try editor.save(using: model)
        XCTAssertEqual(keys.writes, 1, "无变化时不重复写凭据")
    }

    func testSourceChangesInvalidateOnlyDraftCatalogAndDiscardRestoresIt() throws {
        let (model, _, _, editor, _) = try fixture()
        let original = editor.value
        editor.value.name = "改名称"
        XCTAssertEqual(editor.value.fetchedModels, original.fetchedModels)
        editor.value.baseAddress = "https://other.example/v1"
        XCTAssertTrue(editor.value.fetchedModels.isEmpty)
        XCTAssertEqual(model.instance(original.id)?.fetchedModels, original.fetchedModels)
        editor.discard()
        XCTAssertEqual(editor.value, original)
        XCTAssertFalse(editor.hasChanges)
        let revision = editor.sourceRevision
        editor.apiKey = "different-key"
        XCTAssertTrue(editor.value.fetchedModels.isEmpty)
        XCTAssertNotEqual(editor.sourceRevision, revision, "旧来源的异步列表结果必须失效")
        editor.discard()
        var second = ServiceInstance(provider: .claude)
        second.fetchedModels = ["claude-model"]
        try editor.load(second, using: model)
        XCTAssertEqual(editor.value.fetchedModels, ["claude-model"], "切换服务加载缓存不能触发来源编辑失效")
        XCTAssertFalse(editor.hasChanges)
    }

    func testSaveFailurePreservesStoredConfigurationAndDraft() throws {
        let (model, settings, keys, editor, _) = try fixture()
        let original = editor.value
        editor.value.name = "草稿名称"; editor.apiKey = "draft-key"
        keys.failSave = true
        XCTAssertThrowsError(try editor.save(using: model))
        XCTAssertEqual(model.instance(original.id), original)
        XCTAssertEqual(settings.serviceInstances, [original])
        XCTAssertEqual(keys.values[original.configuration.credentialAccount], "saved-key")
        XCTAssertEqual(editor.apiKey, "draft-key")
        XCTAssertTrue(editor.hasChanges)
        keys.failSave = false
        try editor.save(using: model)
        XCTAssertFalse(editor.hasChanges)
    }

    func testVerifyUsesDraftIncludingEmptyKeyWithoutSavingOrRememberingProtocol() async throws {
        let (model, settings, keys, editor, tester) = try fixture()
        let original = editor.value
        // 相同地址、模型时，旧验证逻辑会持久化协议探测结果；草稿验证不得这样做。
        editor.apiKey = ""
        try editor.verify(using: model)
        for _ in 0..<100 where model.isTestingConfiguration { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.configurationTestSucceeded)
        var requests = await tester.received
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.1, "", "明确清空的草稿 Key 不能回退到已保存 Key")
        XCTAssertEqual(model.instance(original.id), original)
        XCTAssertEqual(settings.serviceInstances, [original])
        XCTAssertEqual(keys.writes, 0)
        editor.value.baseAddress = "https://draft.example/v1"
        editor.value.model = "draft-model"; editor.apiKey = "draft-key"
        try editor.verify(using: model)
        for _ in 0..<100 where model.isTestingConfiguration { try await Task.sleep(for: .milliseconds(10)) }
        requests = await tester.received
        XCTAssertEqual(requests.last?.0.endpoint, "https://draft.example/v1/responses")
        XCTAssertEqual(requests.last?.0.model, "draft-model")
        XCTAssertEqual(requests.last?.1, "draft-key")
        XCTAssertEqual(model.instance(original.id), original)
    }

    func testEditingDraftCancelsPreviousVerificationBeforeStartingTheNextOne() throws {
        let (model, _, _, editor, _) = try fixture()
        try editor.verify(using: model)
        XCTAssertTrue(model.isTestingConfiguration)
        editor.value.baseAddress = "https://edited.example/v1"
        XCTAssertFalse(model.isTestingConfiguration, "编辑应立即取消旧验证，不能等异步界面刷新再取消新验证")
        try editor.verify(using: model)
        XCTAssertTrue(model.isTestingConfiguration)
        editor.apiKey = "edited-key"
        XCTAssertFalse(model.isTestingConfiguration)
        model.clearConfigurationTestResult()
    }

    func testDepartureCancelDiscardSaveAndSaveFailure() throws {
        let (model, _, keys, editor, _) = try fixture()
        var departures = 0
        editor.requestDeparture { departures += 1 }
        XCTAssertEqual(departures, 1)
        editor.value.model = "unsaved-model"
        editor.requestDeparture { departures += 1 }
        XCTAssertTrue(editor.confirmsDeparture)
        XCTAssertEqual(departures, 1)
        editor.cancelDeparture()
        XCTAssertTrue(editor.hasChanges)
        XCTAssertEqual(departures, 1)
        editor.requestDeparture { departures += 1 }
        editor.discardAndDepart()
        XCTAssertFalse(editor.hasChanges)
        XCTAssertEqual(departures, 2)
        editor.value.model = "saved-model"; editor.apiKey = "draft-key"
        editor.requestDeparture { departures += 1 }
        keys.failSave = true
        XCTAssertThrowsError(try editor.saveAndDepart(using: model))
        XCTAssertTrue(editor.hasChanges)
        XCTAssertEqual(departures, 2, "保存失败不能离开页面")
        keys.failSave = false
        try editor.saveAndDepart(using: model)
        XCTAssertEqual(departures, 3)
        XCTAssertEqual(model.instance(editor.value.id)?.model, "saved-model")
        XCTAssertFalse(editor.confirmsDeparture)
    }

    func testCredentialReadFailureCannotOverwriteSavedKey() throws {
        let (model, _, keys, editor, _) = try fixture()
        let original = editor.value
        keys.failRead = true
        XCTAssertThrowsError(try editor.load(original, using: model))
        editor.value.name = "名称草稿"
        XCTAssertThrowsError(try editor.save(using: model))
        XCTAssertThrowsError(try editor.verify(using: model))
        XCTAssertEqual(keys.writes, 0)
        XCTAssertEqual(model.instance(original.id), original)
    }

    func testNativeWindowCloseDefersToDraftDepartureDecision() throws {
        _ = NSApplication.shared
        let (_, _, _, editor, _) = try fixture()
        let window = SettingsCloseConfirmingWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hook = SettingsServiceCloseGuardView()
        window.contentView = hook
        var departures = 0
        hook.permitsClose = { _ in
            guard editor.hasChanges else { return true }
            editor.requestDeparture { departures += 1 }
            return false
        }
        hook.install()
        editor.value.model = "unsaved-model"
        window.performClose(nil)
        XCTAssertTrue(editor.confirmsDeparture)
        XCTAssertEqual(departures, 0)
        editor.cancelDeparture()
        XCTAssertTrue(editor.hasChanges)
        window.performClose(nil)
        editor.discardAndDepart()
        XCTAssertEqual(departures, 1)
        XCTAssertFalse(editor.hasChanges)
        XCTAssertEqual(window.permitsClose?(), true)
    }

}

extension SettingsServiceDraftTests {
    private func settingsWindow(for model: TranslationModel, in directory: URL) throws -> SettingsWindowController {
        let hotKey = HotKeyManager(defaults: nil, scope: .local)
        let defaults = try XCTUnwrap(isolatedDefaults())
        return SettingsWindowController(model: model, inputHotKeyManager: hotKey, replacementHotKeyManager: hotKey,
            hotKeyManager: hotKey, screenshotHotKeyManager: hotKey, pinVisibilityHotKeyManager: hotKey,
            clipboardPinHotKeyManager: hotKey, ocrShortcuts: OCRShortcuts(defaults: nil),
            imageEntryShortcuts: ImageEntryShortcuts(defaults: nil), closePinHotKeyManager: hotKey,
            closeAllPinsHotKeyManager: hotKey, regionCaptureHotKeyManager: hotKey, fullCaptureHotKeyManager: hotKey,
            previousCaptureHotKeyManager: hotKey,
            launchAtLogin: LaunchAtLoginController(service: DraftLoginService(), logger: NoopDiagnosticLogger()),
            history: HistoryStore(fileURL: directory.appendingPathComponent("history.json"), defaults: defaults),
            dictionaryManager: ECDictionaryManager(databaseURL: directory.appendingPathComponent("dictionary.db")),
            diagnostics: NoopDiagnosticLogger())
    }

    func testSettingsWindowLoadsCurrentModelLazilyAndReusesItsContent() throws {
        _ = NSApplication.shared
        let (model, _, _, _, _) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try settingsWindow(for: model, in: directory)
        XCTAssertFalse(controller.isWindowLoaded)
        model.primaryLanguage = "ja"
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        defer { controller.close() }
        let host = try XCTUnwrap(window.contentView as? NSHostingView<SettingsView>)
        XCTAssertTrue(host.rootView.model === model)
        XCTAssertEqual(host.rootView.model.primaryLanguage, "ja")
        controller.close()
        controller.showWindow(nil)
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(window.contentView === host)
    }

    func testConfirmedSettingsCloseClearsKeyRevealAndTemporaryFeedback() async throws {
        _ = NSApplication.shared
        let (model, _, _, _, _) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try settingsWindow(for: model, in: directory)
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window as? SettingsCloseConfirmingWindow)
        defer { controller.close() }
        let host = try XCTUnwrap(window.contentView as? NSHostingView<SettingsView>)
        for _ in 0..<20 where window.onClose == nil {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        XCTAssertNotNil(window.onClose)
        let root = host.rootView
        let feedback = root.pageFeedback
        let hotKey = root.inputHotKeyManager
        XCTAssertTrue(hotKey.update(.inputDefault))
        feedback.keyIsRevealed = true
        feedback.serviceOperation = .saved
        feedback.shortcutResetIssues[ObjectIdentifier(hotKey)] = .key("couldNotRestoreTheDefault")

        let permitsClose = window.permitsClose
        window.permitsClose = { false }
        window.performClose(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(feedback.keyIsRevealed)
        XCTAssertNotNil(feedback.serviceOperation)

        window.permitsClose = permitsClose
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(feedback.keyIsRevealed)
        XCTAssertNil(feedback.serviceOperation)
        XCTAssertTrue(feedback.shortcutResetIssues.isEmpty)
        XCTAssertEqual(hotKey.shortcut, .inputDefault)
    }

    private func segmentedControl(in view: NSView) -> SlidingSegmentedControl? {
        if let control = view as? SlidingSegmentedControl { return control }
        return view.subviews.lazy.compactMap { self.segmentedControl(in: $0) }.first
    }

    private func waitForSegment(_ selection: Int, in control: SlidingSegmentedControl) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while control.selectedSegment != selection && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testFrameOlderThanConfirmedClickDoesNotRevertSelection() throws {
        let options = (0..<3).map { SettingsSegmentedOption(value: $0, title: ["慢", "正常", "快"][$0]) }
        var writes: [Int] = []
        func frame(_ snapshot: Int, label: String) -> SettingsSegmentedControl<Int> {
            SettingsSegmentedControl(selection: Binding(get: { snapshot }, set: { writes.append($0) }),
                                     options: options, accessibilityLabel: label)
        }
        let host = NSHostingView(rootView: frame(1, label: "语速"))
        host.layoutSubtreeIfNeeded()
        let control = try XCTUnwrap(segmentedControl(in: host))
        control.selectedSegment = 2
        _ = control.sendAction(control.action, to: control.target)
        XCTAssertEqual(writes, [2])
        // 确认帧：携带用户刚选的“快”。
        host.rootView = frame(2, label: "确认快")
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(control.selectedSegment, 2)
        // 更旧的一帧：点击之前求值的“正常”，现在才应用到控件。
        host.rootView = frame(1, label: "迟到旧值")
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(control.selectedSegment, 2, "确认后的迟到旧值不能把原生选择退回旧选项")
        XCTAssertEqual(writes, [2], "刷新不能写回绑定")
    }

    func testPendingSelectionTimeoutReconcilesRejectedWriteAndExternalChange() async throws {
        let options = (0..<3).map { SettingsSegmentedOption(value: $0, title: "选项\($0)") }
        var authoritative = 1, writes = 0
        let binding = Binding(get: { authoritative }, set: { _ in writes += 1 })
        let host = NSHostingView(rootView: SettingsSegmentedControl(selection: binding, options: options, accessibilityLabel: "拒绝写入"))
        host.layoutSubtreeIfNeeded()
        let control = try XCTUnwrap(segmentedControl(in: host))
        control.selectedSegment = 2
        _ = control.sendAction(control.action, to: control.target)
        XCTAssertEqual(control.selectedSegment, 2)
        try await waitForSegment(1, in: control)
        XCTAssertEqual(control.selectedSegment, 1, "绑定拒绝写入且没有任何刷新时也必须恢复同步")
        XCTAssertEqual(writes, 1, "超时不得重放动作或写回绑定")
        control.selectedSegment = 2
        _ = control.sendAction(control.action, to: control.target)
        authoritative = 0
        host.rootView = SettingsSegmentedControl(selection: binding, options: options, accessibilityLabel: "外部变更")
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(control.selectedSegment, 2)
        try await waitForSegment(0, in: control)
        XCTAssertEqual(control.selectedSegment, 0, "有待确认动作时外部值也只暂缓，不能永久忽略")
        XCTAssertEqual(writes, 2)
        authoritative = 1
        host.rootView = SettingsSegmentedControl(selection: binding, options: options, accessibilityLabel: "正常外部同步")
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(control.selectedSegment, 1, "确认期限之外的外部变更应立即应用")
    }
}

private final class DraftLoginService: LaunchAtLoginServicing {
    let state: LaunchAtLoginState = .disabled
    func setEnabled(_ enabled: Bool) throws { XCTFail("设置窗口测试不应修改登录项") }
}
