import ApplicationServices
import AppKit
import os
import XCTest
@testable import Seven

private struct ReplacementCredentials: CredentialStoring {
    func read(account: String) throws -> String { "" }
    func save(_ value: String, account: String) throws {}
}

private struct ReplacementDictionary: DictionaryServing {
    func lookup(_ text: String) async throws -> DictionaryEntry? { nil }
}

private struct ReplacementAccessibilityStub: FrozenSmartAccessibilityAttributes {
    private struct State: Sendable {
        var enabled: Bool
        var writes: [Bool] = []
        var reads = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(enabled: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(enabled: enabled))
    }

    func read(_ attribute: FrozenSmartAccessibilityAttribute, in pid: pid_t) -> Bool? {
        guard attribute == .manual else { return nil }
        return state.withLock {
            $0.reads += 1
            return $0.enabled
        }
    }

    func set(_ value: Bool, for attribute: FrozenSmartAccessibilityAttribute, in pid: pid_t) -> AXError {
        guard attribute == .manual else { return .attributeUnsupported }
        state.withLock {
            $0.enabled = value
            $0.writes.append(value)
        }
        return .success
    }

    var enabled: Bool { state.withLock { $0.enabled } }
    var writes: [Bool] { state.withLock { $0.writes } }
    var reads: Int { state.withLock { $0.reads } }
}

private actor ReplacementService: OnlineTranslationServing {
    private(set) var calls = 0
    private(set) var receivedTexts: [String] = []
    var continuation: CheckedContinuation<OnlineTranslationOutput, Error>?
    let waits: Bool
    init(waits: Bool = false) { self.waits = waits }
    func translate(_ request: OnlineTranslationRequest) async throws -> OnlineTranslationOutput {
        calls += 1
        receivedTexts.append(request.text)
        if waits { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return .init(text: "你好", dictionaryEntry: nil)
    }
    func finish() {
        continuation?.resume(returning: .init(text: "迟到的结果", dictionaryEntry: nil)); continuation = nil
    }
}

@MainActor
private final class ReplacementTargetStub: InputReplacementTargeting {
    let snapshot: InputReplacementSnapshot
    var changed = false
    var preparedText: String?
    var translationText: String { preparedText ?? snapshot.text }
    var preparation: (() async throws -> Void)?
    var beforeWrite: (() async -> Void)?
    func prepare() async throws { try await preparation?() }
    private(set) var writes: [String] = []
    init(value: String = "hello") throws {
        snapshot = try .init(value: value, range: NSRange(location: (value as NSString).length, length: 0))
    }
    func replace(with text: String) async throws {
        guard !changed else { throw InputReplacementError.contentChanged }
        await beforeWrite?()
        writes.append(text)
    }
}

@MainActor
final class InputReplacementTests: XCTestCase {
    private func fixtures(service: ReplacementService, second: ReplacementService = ReplacementService()) throws -> (TranslationModel, UserDefaults, String) {
        let suite = "ReplacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defaults.set(false, forKey: "customServiceEnabled")
        defaults.set(false, forKey: "appleTranslationEnabled")
        defaults.set(true, forKey: "googleEnabled")
        defaults.set(false, forKey: "youdaoEnabled")
        return (TranslationModel(dictionaryService: ReplacementDictionary(), youdaoService: second, googleService: service, credentials: ReplacementCredentials(),
                                 settings: SettingsStore(defaults: defaults)), defaults, suite)
    }

    private func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("会话未在预期时间内结束")
    }

    func testMissingAccessibilityOpensGuideWithoutStartingTranslation() throws {
        let (model, _, _) = try fixtures(service: ReplacementService())
        var authorizations = 0
        var modelRequests = 0
        let coordinator = InputReplacementCoordinator(
            capture: { _ in throw SelectionReadError.accessibilityPermission },
            authorize: { authorizations += 1 },
            makeModel: {
                modelRequests += 1
                return model
            }
        )
        coordinator.start(pid: 1)
        XCTAssertEqual(authorizations, 1)
        XCTAssertEqual(modelRequests, 0)
        XCTAssertFalse(coordinator.isRunning)
    }

    func testUnrelatedReplacementErrorDoesNotOpenPermissionGuide() throws {
        let (model, _, _) = try fixtures(service: ReplacementService())
        var authorizations = 0
        let coordinator = InputReplacementCoordinator(
            capture: { _ in throw InputReplacementError.unreadable },
            authorize: { authorizations += 1 },
            makeModel: { model }
        )
        coordinator.start(pid: 1)
        XCTAssertEqual(authorizations, 0)
        coordinator.cancel()
    }

    func testMissingAppFocusUsesSystemFocusFromTheSameFrontmostPID() throws {
        let pid: pid_t = 42
        let element = AXUIElementCreateApplication(pid)
        let focused = try InputReplacementTarget.focused(pid: pid, frontmostPID: { pid }, appFocus: { _ in nil },
                                                        systemFocus: { element })
        XCTAssertTrue(CFEqual(focused, element))
    }

    func testSystemFocusFromAnotherProcessIsRejected() {
        let pid: pid_t = 42
        let element = AXUIElementCreateApplication(pid + 1)
        XCTAssertThrowsError(try InputReplacementTarget.focused(pid: pid, frontmostPID: { pid },
                                                               appFocus: { _ in nil }, systemFocus: { element })) {
            XCTAssertEqual($0 as? InputReplacementError, .unreadable)
        }
    }

    func testSystemFocusIsRejectedIfTheFrontmostAppChangesDuringLookup() {
        let pid: pid_t = 42
        let element = AXUIElementCreateApplication(pid)
        var frontmostPID = pid
        XCTAssertThrowsError(try InputReplacementTarget.focused(pid: pid, frontmostPID: { frontmostPID },
            appFocus: { _ in nil }, systemFocus: {
                frontmostPID += 1
                return element
            })) {
            XCTAssertEqual($0 as? InputReplacementError, .focusChanged)
        }
    }

    func testSnapshotPreservesUTF16SelectionAndSurroundingWhitespace() throws {
        let value = "  🥝hello\n tail  "
        let range = (value as NSString).range(of: "hello")
        let snapshot = try InputReplacementSnapshot(value: value, range: range)
        XCTAssertFalse(snapshot.replacesWholeInput)
        XCTAssertEqual(snapshot.text, "hello")
        XCTAssertEqual(snapshot.replacing(with: "你好"), "  🥝你好\n tail  ")
        XCTAssertNotEqual(snapshot, try .init(value: value, range: NSRange(location: 0, length: 5)))
    }

    func testOnlyExplicitEmptySelectionMeansWholeInput() throws {
        let snapshot = try InputReplacementSnapshot(value: "🥝 hello", range: NSRange(location: 2, length: 0))
        XCTAssertTrue(snapshot.replacesWholeInput)
        XCTAssertEqual(snapshot.text, "🥝 hello")
        XCTAssertEqual(snapshot.replacing(with: "你好"), "你好")
        for range in [NSRange(location: NSNotFound, length: 0), NSRange(location: -1, length: 0),
                      NSRange(location: 0, length: -1), NSRange(location: 20, length: 0), NSRange(location: 1, length: 20)] {
            XCTAssertThrowsError(try InputReplacementSnapshot(value: "hello", range: range))
        }
    }

    func testSingleProviderDoesNotStartOtherEnabledServicesOrChangeSettings() async throws {
        let google = ReplacementService(), youdao = ReplacementService()
        let (model, defaults, suite) = try fixtures(service: google, second: youdao)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.setServiceEnabled(.ecdict, enabled: true)
        model.setServiceEnabled(.youdao, enabled: true)
        XCTAssertEqual(model.displayedServiceResults.first?.id, .ecdict)
        let before = defaults.dictionaryRepresentation()
        XCTAssertEqual(try model.beginInputReplacement("hello"), .youdao)
        try await settle { !model.isLoading }
        XCTAssertEqual(model.serviceResults.map(\.id), [.youdao])
        XCTAssertEqual(model.serviceResults.first?.text, "你好")
        let googleCalls = await google.calls, youdaoCalls = await youdao.calls
        XCTAssertEqual(googleCalls, 0); XCTAssertEqual(youdaoCalls, 1)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before as NSDictionary)
    }

    func testPausedServicesAreNotEnabledByReplacement() throws {
        let (model, defaults, suite) = try fixtures(service: ReplacementService())
        defer { defaults.removePersistentDomain(forName: suite) }
        model.setServiceExpanded(.google, expanded: false)
        model.setServiceExpanded(.youdao, expanded: false)
        XCTAssertThrowsError(try model.beginInputReplacement("hello"))
        XCTAssertFalse(model.isServiceExpanded(.google)); XCTAssertFalse(model.isServiceExpanded(.youdao))
    }

    func testCoordinatorWritesOnlyCompletedTranslation() async throws {
        let (model, defaults, suite) = try fixtures(service: ReplacementService())
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = try ReplacementTargetStub()
        let coordinator = InputReplacementCoordinator(capture: { _ in target }, makeModel: { model })
        coordinator.start(pid: 1)
        try await settle { !coordinator.isRunning }
        XCTAssertEqual(target.writes, ["你好"])
        coordinator.cancel()
    }

    func testCoordinatorRetriesUntilTheBrowserPublishesFocus() async throws {
        let (model, defaults, suite) = try fixtures(service: ReplacementService())
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = try ReplacementTargetStub()
        let backend = ReplacementAccessibilityStub()
        let restorations = FrozenSmartAccessibilityRestorations()
        let session = FrozenSmartAccessibilitySession(attributes: backend, restorations: restorations)
        let trace = OSAllocatedUnfairLock(initialState: [String]())
        var attempts = 0
        let coordinator = InputReplacementCoordinator(capture: { _ in
            attempts += 1
            guard attempts >= 3 else { throw InputReplacementError.focusUnavailable }
            return target
        }, makeAccessibilitySession: { session }, monitorFocusInterruption: { _ in {} }, trace: { event in
            trace.withLock { $0.append(event) }
        }, makeModel: { model })

        coordinator.start(pid: 1)
        try await settle { !coordinator.isRunning }

        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(target.writes, ["你好"])
        await restorations.beginTermination().value
        XCTAssertEqual(backend.writes, [true, false])
        XCTAssertFalse(backend.enabled)
        #if DEBUG || SEVEN_DEVELOPMENT
        XCTAssertEqual(trace.withLock { $0 }, ["manual.before.off", "manual.enable.0", "manual.after.capture_ready.on"])
        #endif
        coordinator.cancel()
    }

    func testAlreadyEnabledAccessibilityChecksFocusOnlyOnceMore() async throws {
        let (model, defaults, suite) = try fixtures(service: ReplacementService())
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = ReplacementAccessibilityStub(enabled: true)
        let session = FrozenSmartAccessibilitySession(attributes: backend, restorations: .init())
        var attempts = 0
        let coordinator = InputReplacementCoordinator(capture: { _ in
            attempts += 1
            if attempts == 3 { throw InputReplacementError.readOnly }
            throw InputReplacementError.focusUnavailable
        }, makeAccessibilitySession: { session }, monitorFocusInterruption: { _ in {} }, trace: nil, makeModel: { model })
        defer { coordinator.cancel() }

        coordinator.start(pid: 1)
        try await settle { !coordinator.isRunning }

        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(backend.enabled)
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertEqual(backend.reads, 1)
    }

    func testOrdinaryCancelKeepsAccessibilityEnabledUntilWriteFinishes() async throws {
        try await checkAccessibilityDuringWrite(expectedEnabled: true) { $0.cancel() }
    }

    func testTerminationQueuesAccessibilityRestorationDuringWrite() async throws {
        try await checkAccessibilityDuringWrite(expectedEnabled: false) { coordinator in
            coordinator.terminate()
            coordinator.terminate()
        }
    }

    private func checkAccessibilityDuringWrite(
        expectedEnabled: Bool, action: @escaping @MainActor (InputReplacementCoordinator) -> Void
    ) async throws {
        let (model, defaults, suite) = try fixtures(service: ReplacementService())
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = ReplacementAccessibilityStub()
        let restorations = FrozenSmartAccessibilityRestorations()
        let session = FrozenSmartAccessibilitySession(attributes: backend, restorations: restorations)
        let target = try ReplacementTargetStub()
        let coordinator = InputReplacementCoordinator(capture: { _ in
            guard backend.enabled else { throw InputReplacementError.focusUnavailable }
            return target
        }, makeAccessibilitySession: { session }, monitorFocusInterruption: { _ in {} }, makeModel: { model })
        defer { coordinator.cancel() }
        target.beforeWrite = { [weak coordinator] in
            guard let coordinator else { return }
            XCTAssertTrue(backend.enabled)
            action(coordinator)
            // 等待此前已提交的恢复，避免用时序猜测取消是否提前释放了模式。
            await restorations.beginTermination().value
            XCTAssertEqual(backend.enabled, expectedEnabled)
        }

        coordinator.start(pid: 1)
        try await settle { !coordinator.isRunning }
        await restorations.beginTermination().value

        XCTAssertEqual(target.writes, ["你好"])
        XCTAssertEqual(backend.writes, [true, false])
        XCTAssertFalse(backend.enabled)
    }

    func testInputDuringFocusWarmupCancelsTheReplacement() async throws {
        let (model, defaults, suite) = try fixtures(service: ReplacementService())
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = FrozenSmartAccessibilitySession(attributes: ReplacementAccessibilityStub(), restorations: .init())
        var interruption: (@MainActor () -> Void)?
        var didStopMonitoring = false
        var requests = 0
        let coordinator = InputReplacementCoordinator(capture: { _ in
            throw InputReplacementError.focusUnavailable
        }, makeAccessibilitySession: { session }, monitorFocusInterruption: { onInterruption in
            interruption = onInterruption
            return { didStopMonitoring = true }
        }, makeModel: {
            requests += 1
            return model
        })

        coordinator.start(pid: 1)
        try await settle { interruption != nil }
        interruption?()
        try await settle { didStopMonitoring }

        XCTAssertEqual(requests, 0)
        XCTAssertFalse(coordinator.isRunning)
        await session.finish().value
    }

    func testChangedTargetIsNotWritten() async throws {
        let service = ReplacementService(waits: true)
        let (model, defaults, suite) = try fixtures(service: service)
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = try ReplacementTargetStub()
        let coordinator = InputReplacementCoordinator(capture: { _ in target }, makeModel: { model })
        coordinator.start(pid: 1)
        try await settle { model.serviceResults.first?.phase == .loading }
        // 等到模拟服务确实挂起后再改变输入目标。
        for _ in 0..<100 {
            if await service.calls > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        target.changed = true
        await service.finish()
        try await settle { !coordinator.isRunning }
        XCTAssertTrue(target.writes.isEmpty)
        coordinator.cancel()
    }

    func testCancelIgnoresLateResult() async throws {
        let service = ReplacementService(waits: true)
        let (model, defaults, suite) = try fixtures(service: service)
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = try ReplacementTargetStub()
        let coordinator = InputReplacementCoordinator(capture: { _ in target }, makeModel: { model })
        coordinator.start(pid: 1)
        for _ in 0..<100 {
            if await service.calls > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        coordinator.cancel()
        await service.finish()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(coordinator.isRunning); XCTAssertTrue(target.writes.isEmpty)
    }

    func testUnreadableTargetNeverStartsTranslation() throws {
        var modelCreations = 0
        let (model, defaults, suite) = try fixtures(service: ReplacementService())
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = InputReplacementCoordinator(capture: { _ in throw InputReplacementError.unreadable }, makeModel: {
            modelCreations += 1
            return model
        })
        coordinator.start(pid: 1)
        XCTAssertEqual(modelCreations, 0)
        XCTAssertFalse(coordinator.isRunning)
        coordinator.cancel()
    }

    func testReplacementShortcutDefaultsAndIndependentStorage() throws {
        let suite = "ReplacementHotKey.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = HotKeyManager(defaults: defaults, storageKey: "replacementHotKey.v1", defaultShortcut: .replacementDefault,
                                    identifierID: 4, actionLabel: "翻译并替换")
        XCTAssertEqual(manager.shortcut, KeyboardShortcut.replacementDefault)
        XCTAssertNotNil(defaults.data(forKey: "replacementHotKey.v1"))
        XCTAssertNil(defaults.data(forKey: "selectionHotKey.v1"))
        XCTAssertFalse(manager.shortcut.conflictsWithSystemShortcut)
    }

    func testNativeSelectAllWaitsForDelayedAccessibilitySelection() async throws {
        let original = try InputReplacementSnapshot(value: "hello 🥝", range: NSRange(location: 8, length: 0))
        let selected = try InputReplacementSnapshot(value: original.value, range: original.replacementRange)
        var current = original
        var commands = 0, polls = 0
        try await InputReplacementSelection.selectWholeInput(original: original, read: { current }, checkTarget: {},
            selectAll: { commands += 1 }, pause: {
                polls += 1
                if polls == 3 { current = selected }
            })
        XCTAssertEqual(commands, 1); XCTAssertEqual(polls, 3)
    }

    func testNativeSelectAllRejectsContentChangesAndUnconfirmedSelection() async throws {
        let original = try InputReplacementSnapshot(value: "hello", range: NSRange(location: 5, length: 0))
        var current = original
        let unchanged = try await InputReplacementSelection.selectWholeInput(original: original, read: { current }, checkTarget: {},
            selectAll: {}, attempts: 2, pause: {})
        XCTAssertEqual(unchanged, original, "全选无选区时应继续复制，由复制结果决定")
        do {
            try await InputReplacementSelection.selectWholeInput(original: original, read: { current }, checkTarget: {},
                selectAll: { current = try .init(value: "changed", range: NSRange(location: 0, length: 7)) }, pause: {})
            XCTFail("不能覆盖用户刚输入的文字")
        } catch { XCTAssertEqual(error as? InputReplacementError, .contentChanged) }
    }

    func testNativeSelectAllDoesNotBroadenExistingSelectionOrIgnoreFocusChange() async throws {
        let selected = try InputReplacementSnapshot(value: "hello", range: NSRange(location: 0, length: 2))
        var commands = 0
        do {
            try await InputReplacementSelection.selectWholeInput(original: selected, read: { selected }, checkTarget: {},
                selectAll: { commands += 1 }, pause: {})
            XCTFail("现有选区不能扩大为全文")
        } catch { XCTAssertEqual(error as? InputReplacementError, .selectionChanged) }
        let original = try InputReplacementSnapshot(value: "hello", range: NSRange(location: 5, length: 0))
        do {
            try await InputReplacementSelection.selectWholeInput(original: original, read: { original },
                checkTarget: { throw InputReplacementError.focusChanged }, selectAll: { commands += 1 }, pause: {})
            XCTFail("焦点改变时不能全选")
        } catch { XCTAssertEqual(error as? InputReplacementError, .focusChanged) }
        XCTAssertEqual(commands, 0)
    }

    func testReplacementCapsuleKeepsAnchorAndCancelHitAreaAcrossStates() throws {
        _ = NSApplication.shared
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let hud = InputReplacementHUD()
        var cancelled = false
        hud.begin(anchor: NSScreen.main?.visibleFrame.origin, cancel: { cancelled = true })
        defer { hud.close() }
        let panel = try XCTUnwrap(NSApp.windows.first { !existingWindows.contains(ObjectIdentifier($0)) } as? NSPanel)
        XCTAssertFalse(panel.isKeyWindow)
        let origin = panel.frame.origin
        let root = try XCTUnwrap(panel.contentView)
        let button = try XCTUnwrap(screenshotDescendants(of: root).compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("dismiss") })
        button.performClick(nil)
        XCTAssertTrue(cancelled)
        hud.prepareForWrite()
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(button.isEnabled)
        hud.showResult("已替换", success: true)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.frame.origin, origin)
        XCTAssertTrue(button.isHidden)
        let failureMessage: LocalizedMessage = "输入位置或内容已变化"
        let failureDetail: LocalizedMessage = "前台应用已变化，已停止替换。"
        hud.showResult(failureMessage, success: false, detail: failureDetail)
        let messageField = try XCTUnwrap(screenshotDescendants(of: root).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityHelp() == failureDetail.text })
        XCTAssertEqual(messageField.stringValue, failureMessage.text)
        XCTAssertEqual(root.toolTip, failureDetail.text)
        XCTAssertEqual(panel.frame.origin, origin)
        XCTAssertTrue(button.isHidden)
        XCTAssertLessThanOrEqual(panel.frame.width, Design.ReplacementHUD.maximumWidth)
    }

    func testEmptyInputAndPlaceholderAreNotTranslationContent() throws {
        for value in ["", "  ", "\n\t"] {
            let snapshot = try InputReplacementSnapshot(value: value, range: NSRange(location: 0, length: 0))
            XCTAssertThrowsError(try snapshot.validateContent()) { XCTAssertEqual($0 as? InputReplacementError, .empty) }
        }
        let placeholder = "Type a message..."
        let snapshot = try InputReplacementSnapshot(value: placeholder, range: NSRange(location: 0, length: 0))
        XCTAssertThrowsError(try snapshot.validateContent(characterCount: 0))
        XCTAssertThrowsError(try snapshot.validateContent(placeholder: placeholder))
        // 真正输入了与占位文案相同的文字，并有正字符数作证时，仍允许翻译。
        XCTAssertNoThrow(try snapshot.validateContent(characterCount: placeholder.utf16.count, placeholder: placeholder))
        let regular = try InputReplacementSnapshot(value: "actual text", range: NSRange(location: 0, length: 0))
        XCTAssertNoThrow(try regular.validateContent(placeholder: placeholder))
    }

    func testEmptyTargetAndWhitespaceNeverStartRequests() async throws {
        let service = ReplacementService()
        let (model, defaults, suite) = try fixtures(service: service)
        defer { defaults.removePersistentDomain(forName: suite) }
        var modelsCreated = 0
        let emptyTarget = try ReplacementTargetStub(value: "")
        let coordinator = InputReplacementCoordinator(capture: { _ in emptyTarget }, makeModel: {
            modelsCreated += 1
            return model
        })
        coordinator.start(pid: 1)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(modelsCreated, 0)
        for value in ["", " ", "\n\t"] {
            XCTAssertThrowsError(try model.beginInputReplacement(value))
        }
        let requests = await service.calls
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(model.serviceResults.isEmpty)
        XCTAssertTrue(emptyTarget.writes.isEmpty)
        coordinator.cancel()
    }

    func testPlaceholderAXValueWithoutNativeCopyNeverCreatesTranslationModel() async throws {
        let service = ReplacementService()
        let (model, defaults, suite) = try fixtures(service: service)
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = try ReplacementTargetStub(value: "Type a message...")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("user clipboard", forType: .string)
        target.preparation = {
            try await InputReplacementClipboardProbe.verify(pasteboard: board,
                copy: {}, checkTarget: {}, attempts: 2, pause: {})
        }
        var modelsCreated = 0
        let coordinator = InputReplacementCoordinator(capture: { _ in target }, makeModel: {
            modelsCreated += 1
            return model
        })
        coordinator.start(pid: 1)
        try await settle { !coordinator.isRunning }
        XCTAssertEqual(modelsCreated, 0)
        XCTAssertTrue(target.writes.isEmpty)
        XCTAssertEqual(board.string(forType: .string), "user clipboard")
        let requests = await service.calls
        XCTAssertEqual(requests, 0)
        coordinator.cancel()
    }

    func testNativeCopyMustMatchAndRestoresClipboardAfterSuccessfulCheck() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("user clipboard", forType: .string)
        try await InputReplacementClipboardProbe.verify(pasteboard: board, copy: {
            board.clearContents()
            board.setString("hello", forType: .string)
        }, checkTarget: {}, pause: {})
        XCTAssertEqual(board.string(forType: .string), "user clipboard")
        var round = 0
        do {
            try await InputReplacementClipboardProbe.verify(pasteboard: board, copy: {
                round += 1
                board.clearContents()
                board.setString(round == 1 ? "first native copy" : "actual current value", forType: .string)
            }, checkTarget: {}, pause: {})
            XCTFail("复制与 AX 内容不一致不能翻译")
        } catch { XCTAssertEqual(error as? InputReplacementError, .contentChanged) }
        // 不把不属于本次预期复制的剪贴板变化覆盖回旧值。
        XCTAssertEqual(board.string(forType: .string), "actual current value")
    }

    func testCancelWhileCheckingNativeCopyDoesNotStartLateRequest() async throws {
        let service = ReplacementService()
        let (model, defaults, suite) = try fixtures(service: service)
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = try ReplacementTargetStub()
        var completion: CheckedContinuation<Void, Never>?
        target.preparation = { await withCheckedContinuation { completion = $0 } }
        var modelsCreated = 0
        let coordinator = InputReplacementCoordinator(capture: { _ in target }, makeModel: {
            modelsCreated += 1
            return model
        })
        coordinator.start(pid: 1)
        try await settle { completion != nil }
        coordinator.cancel()
        completion?.resume()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(modelsCreated, 0)
        let requests = await service.calls
        XCTAssertEqual(requests, 0)
    }

    func testFailurePresentationMergesReasonsButKeepsSpecificDetails() {
        let changed: [InputReplacementError] = [.focusChanged, .controlChanged, .contentChanged, .selectionChanged]
        let presentations = changed.map { InputReplacementFailurePresentation(error: $0) }
        XCTAssertTrue(presentations.allSatisfy { $0.reasonMessage == .key("inputLocationOrTextChanged") })
        XCTAssertEqual(presentations.map(\.detailMessage), changed.map { $0.issue })
        XCTAssertEqual(InputReplacementFailurePresentation(error: InputReplacementError.failed).reasonMessage,
                       .key("checkTheReplacement"))
        let network = InputReplacementFailurePresentation(error: TranslationError.http(429))
        XCTAssertEqual(network.reasonMessage, .key("translationFailed"))
        XCTAssertEqual(network.detailMessage, .key("tooManyRequestsOrInsufficientQuotaTry"))
        let permission = InputReplacementFailurePresentation(error: SelectionReadError.accessibilityPermission)
        XCTAssertEqual(permission.detailMessage, SelectionReadError.accessibilityPermission.issue)
        XCTAssertNotEqual(permission.reasonMessage, network.reasonMessage)
    }

    func testTwoMissingCopyResponsesAreSilentEmptyInput() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("user clipboard", forType: .string)
        do {
            try await InputReplacementClipboardProbe.verify(pasteboard: board,
                copy: {}, checkTarget: {}, attempts: 2, pause: {})
            XCTFail("无复制响应不能通过校验")
        } catch {
            XCTAssertEqual(error as? InputReplacementError, .empty)
        }
        XCTAssertEqual(board.string(forType: .string), "user clipboard")
    }

    func testEmptyContentEvidencePrecedesSelectionAndDoesNotGuessFromPlaceholder() throws {
        for value: String? in [nil, "", "Type a message..."] {
            XCTAssertThrowsError(try InputReplacementContent.resolve(value: value, characterCount: 0,
                placeholder: nil, documentText: nil)) { XCTAssertEqual($0 as? InputReplacementError, .empty) }
        }
        XCTAssertThrowsError(try InputReplacementContent.resolve(value: "Type a message...", characterCount: nil,
            placeholder: "Type a message...", documentText: nil)) { XCTAssertEqual($0 as? InputReplacementError, .empty) }
        XCTAssertThrowsError(try InputReplacementContent.resolve(value: nil, characterCount: nil,
            placeholder: nil, documentText: nil)) { XCTAssertEqual($0 as? InputReplacementError, .unreadable) }
        XCTAssertThrowsError(try InputReplacementContent.resolve(value: "", characterCount: 12,
            placeholder: nil, documentText: nil)) { XCTAssertEqual($0 as? InputReplacementError, .unreadable) }
        XCTAssertThrowsError(try InputReplacementContent.resolve(value: "hint", characterCount: nil,
            placeholder: nil, documentText: " \n")) { XCTAssertEqual($0 as? InputReplacementError, .empty) }
        XCTAssertEqual(try InputReplacementContent.resolve(value: "hint", characterCount: 5,
            placeholder: "hint", documentText: "hello"), "hello")
    }

    func testConfirmedEmptyIsSilentButUnreadableShowsFailure() throws {
        _ = NSApplication.shared
        let (model, defaults, suite) = try fixtures(service: ReplacementService())
        defer { defaults.removePersistentDomain(forName: suite) }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        var modelsCreated = 0
        let empty = InputReplacementCoordinator(capture: { _ in throw InputReplacementError.empty }, makeModel: {
            modelsCreated += 1
            return model
        })
        empty.start(pid: 1)
        XCTAssertFalse(empty.isRunning)
        XCTAssertTrue(NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) }.allSatisfy { !$0.isVisible })
        let unreadable = InputReplacementCoordinator(capture: { _ in throw InputReplacementError.unreadable }, makeModel: {
            modelsCreated += 1
            return model
        })
        unreadable.start(pid: 1)
        defer { unreadable.cancel(); empty.cancel() }
        let shown = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.isVisible }
        XCTAssertEqual(shown.count, 1)
        let surface = try XCTUnwrap(shown.first?.contentView)
        XCTAssertEqual(surface.toolTip, InputReplacementError.unreadable.issue.text)
        XCTAssertFalse(unreadable.isRunning)
        XCTAssertEqual(modelsCreated, 0)
    }

    func testFormattedCopyReturnsNativeTextAndRestoresAllClipboardTypes() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("user clipboard", forType: .string)
        let expected = "确认空白\n读取失败"
        let copied = "•\t确认空白\r\n•\t读取失败"
        let native = try await InputReplacementClipboardProbe.verify(pasteboard: board, copy: {
            board.clearContents()
            board.setString(copied, forType: .string)
            board.setData(Data("<ul><li>确认空白</li><li>读取失败</li></ul>".utf8), forType: .html)
        }, checkTarget: {}, pause: {})
        XCTAssertEqual(native, copied)
        XCTAssertEqual(board.string(forType: .string), "user clipboard")
        XCTAssertNil(board.data(forType: .html))
        // AX 自身前后出现真实改动仍会拒绝，不因剪贴板格式兼容而放松。
        let before = try InputReplacementSnapshot(value: expected, range: NSRange(location: 0, length: 4))
        let changed = try InputReplacementSnapshot(value: "确认发送\n读取失败", range: before.range)
        XCTAssertThrowsError(try InputReplacementSelection.validate(changed, against: before))
    }

    func testTranslationUsesNativeCopiedTextRatherThanAXSerialization() async throws {
        let service = ReplacementService()
        let (model, defaults, suite) = try fixtures(service: service)
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = try ReplacementTargetStub(value: "确认空白\n读取失败")
        let native = "•\t确认空白\r\n•\t读取失败"
        target.preparation = { target.preparedText = native }
        let coordinator = InputReplacementCoordinator(capture: { _ in target }, makeModel: { model })
        coordinator.start(pid: 1)
        try await settle { !coordinator.isRunning }
        let texts = await service.receivedTexts
        XCTAssertEqual(texts, [native])
        XCTAssertEqual(target.snapshot.value, "确认空白\n读取失败")
        coordinator.cancel()
    }

    func testCopiedRichTextDoesNotRequireMatchingAXOrMarkdownRepresentations() async throws {
        let copied = "周末活动安排\n\n- 上午参观展览。\n- 中午在公园野餐。\n- 下午参加手工活动。\n\n详情见[活动日程](https://example.com/events/schedule)。"
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original clipboard", forType: .string)
        var copies = 0
        let actual = try await InputReplacementClipboardProbe.verify(pasteboard: board, copy: {
            copies += 1
            board.clearContents()
            board.setString(copied, forType: .string)
        }, checkTarget: {}, pause: {})
        XCTAssertEqual(actual, copied)
        XCTAssertEqual(copies, 2)
        XCTAssertEqual(board.string(forType: .string), "original clipboard")

    }

    func testNativeSelectAllUsesReturnedLinkRangeAsBaselineRatherThanDisplayedLength() async throws {
        let value = "正文 示例文件.pdf 附件说明"
        let original = try InputReplacementSnapshot(value: value, range: NSRange(location: 0, length: 0))
        // 模拟链接 chip 在原生坐标中占一位，AXValue 却展开成多个字符。
        let selected = try InputReplacementSnapshot(value: value, range: NSRange(location: 0, length: 5),
                                                    nativeCharacterCount: 5, selectedText: value)
        var current = original
        let baseline = try await InputReplacementSelection.selectWholeInput(original: original, read: { current },
            checkTarget: {}, selectAll: { current = selected }, pause: {})
        XCTAssertEqual(baseline.range, selected.range)
        XCTAssertEqual(baseline.text, value)
        XCTAssertNoThrow(try InputReplacementSelection.validate(current, against: baseline))
        let moved = try InputReplacementSnapshot(value: value, range: NSRange(location: 0, length: 4),
                                                 nativeCharacterCount: 5, selectedText: "正文")
        XCTAssertThrowsError(try InputReplacementSelection.validate(moved, against: baseline))
    }

    func testNativeSelectionCanUseDocumentCoordinatesLargerThanDisplayedValue() throws {
        let snapshot = try InputReplacementSnapshot(value: "链接", range: NSRange(location: 0, length: 30),
            nativeCharacterCount: 30, selectedText: "新版Seven.app")
        XCTAssertEqual(snapshot.text, "新版Seven.app")
        XCTAssertNil(snapshot.replacing(with: "translated"), "不能将原生选区坐标直接套在 AXValue 显示文字上拼接")
    }

    func testWriteVerificationAcceptsActualInsertedTextWhenRichTextWholeValueDiffers() throws {
        let before = try InputReplacementSnapshot(value: "正文 新版Seven.app 尾部", range: NSRange(location: 3, length: 1),
            selectedText: "新版Seven.app")
        XCTAssertTrue(InputReplacementWriteVerification.matches(translated: "New Seven.app", before: before,
            wholeInput: false, insertedText: "New Seven.app", currentValue: "正文 New Seven.app\n尾部", currentDocument: nil))
        XCTAssertFalse(InputReplacementWriteVerification.matches(translated: "New Seven.app", before: before,
            wholeInput: false, insertedText: "old content", currentValue: "正文 old content 尾部", currentDocument: nil))
        XCTAssertTrue(InputReplacementWriteVerification.matches(translated: "Translated text", before: before,
            wholeInput: true, insertedText: nil, currentValue: "Translated text\n", currentDocument: nil))
        XCTAssertFalse(InputReplacementWriteVerification.matches(translated: "Translated text", before: before,
            wholeInput: true, insertedText: nil, currentValue: "Translated text and extra", currentDocument: nil))
    }

    func testFailurePromptAutomaticallyClosesAndDoesNotCloseNewTask() async throws {
        _ = NSApplication.shared
        let service = ReplacementService(waits: true)
        let (model, defaults, suite) = try fixtures(service: service)
        defer { defaults.removePersistentDomain(forName: suite) }
        let previous = Set(NSApp.windows.map(ObjectIdentifier.init))
        var shouldFail = true
        let target = try ReplacementTargetStub()
        let coordinator = InputReplacementCoordinator(capture: { _ in
            if shouldFail { throw InputReplacementError.unreadable }
            return target
        }, makeModel: { model })
        defer { coordinator.cancel() }
        coordinator.start(pid: 1)
        let panel = try XCTUnwrap(NSApp.windows.first { !previous.contains(ObjectIdentifier($0)) })
        XCTAssertTrue(panel.isVisible)
        try await Task.sleep(for: .seconds(Design.ReplacementHUD.resultHold + 0.15))
        XCTAssertFalse(panel.isVisible)
        coordinator.start(pid: 1)
        XCTAssertTrue(panel.isVisible)
        shouldFail = false
        coordinator.start(pid: 1)
        try await settle { model.isLoading }
        XCTAssertTrue(panel.isVisible)
        // 新任务显示进度，旧提示的过期定时器不能将其关闭。
        try await Task.sleep(for: .seconds(Design.ReplacementHUD.resultHold + 0.15))
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertTrue(panel.isVisible)
        coordinator.cancel()
        await service.finish()
    }

}
