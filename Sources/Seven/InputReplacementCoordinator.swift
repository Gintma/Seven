import AppKit
import Combine

/// 与普通翻译浮窗隔离的原地替换会话；同一时间只允许一个写回任务。
@MainActor
final class InputReplacementCoordinator {
    typealias FocusInterruptionMonitor = @MainActor (@escaping @MainActor () -> Void) -> @MainActor () -> Void

    private let capture: @MainActor (pid_t) throws -> any InputReplacementTargeting
    private let makeModel: @MainActor () -> TranslationModel
    private let authorize: @MainActor () -> Void
    private let makeAccessibilitySession: @MainActor () -> FrozenSmartAccessibilitySession
    private let monitorFocusInterruption: FocusInterruptionMonitor
    private let trace: (@Sendable (String) -> Void)?
    private let hud: InputReplacementHUD
    private var model: TranslationModel?
    private var target: (any InputReplacementTargeting)?
    private var resultObserver: AnyCancellable?
    private var timeout: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var accessibilitySession: FrozenSmartAccessibilitySession?
    private var jobID = UUID()
    private var writing = false

    init(capture: @escaping @MainActor (pid_t) throws -> any InputReplacementTargeting = InputReplacementTarget.capture,
         authorize: @escaping @MainActor () -> Void = { PermissionGuide.shared.authorize(.accessibility) },
         makeAccessibilitySession: @escaping @MainActor () -> FrozenSmartAccessibilitySession = { .init() },
         monitorFocusInterruption: @escaping FocusInterruptionMonitor = { callback in
             InputReplacementCoordinator.monitorInputDuringFocusRecovery(callback)
         },
         trace: (@Sendable (String) -> Void)? = nil,
         hud: InputReplacementHUD? = nil,
         makeModel: @escaping @MainActor () -> TranslationModel) {
        self.capture = capture; self.authorize = authorize; self.makeModel = makeModel
        self.makeAccessibilitySession = makeAccessibilitySession
        self.monitorFocusInterruption = monitorFocusInterruption
        #if DEBUG || SEVEN_DEVELOPMENT
        self.trace = trace
        #else
        self.trace = nil
        #endif
        self.hud = hud ?? InputReplacementHUD()
    }

    var isRunning: Bool { target != nil || accessibilitySession != nil || model != nil }

    func start(pid: pid_t) {
        guard !writing else { return }
        cancel()
        hud.setAnchor()
        let id = UUID(); jobID = id
        let captured: (any InputReplacementTargeting)?
        do {
            let target = try capture(pid)
            self.target = target
            try target.snapshot.validateContent()
            captured = target
        } catch InputReplacementError.focusUnavailable {
            captured = nil
            accessibilitySession = makeAccessibilitySession()
        } catch {
            fail(error, anchor: target?.anchor)
            return
        }
        preparationTask = Task { [weak self] in
            guard let self, jobID == id, !Task.isCancelled else { return }
            do {
                let target: any InputReplacementTargeting
                if let captured {
                    target = captured
                } else {
                    target = try await captureAfterPublishingFocus(pid: pid)
                    guard jobID == id, !Task.isCancelled else { return }
                    self.target = target
                    try target.snapshot.validateContent()
                }
                try await target.prepare()
                guard jobID == id, !Task.isCancelled else { return }
                beginTranslation(target: target, id: id)
            } catch {
                guard jobID == id, !Task.isCancelled else { return }
                fail(error, anchor: self.target?.anchor)
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled, let self, self.jobID == id else { return }
            let anchor = self.model == nil ? self.target?.anchor : nil
            self.fail(InputReplacementError.timedOut, anchor: anchor)
        }
    }

    private func captureAfterPublishingFocus(pid: pid_t) async throws -> any InputReplacementTargeting {
        guard let accessibilitySession else { throw InputReplacementError.focusUnavailable }
        let id = jobID
        let stopMonitoring = monitorFocusInterruption { [weak self] in
            guard let self, jobID == id, target == nil else { return }
            cancel()
        }
        defer { stopMonitoring() }
        let preparation = Task.detached(priority: .userInitiated) { [trace] in
            accessibilitySession.requestManualAccessibility(pid, report: trace)
        }
        let requested = await preparation.value
        let deadline = ContinuousClock.now + .seconds(FrozenSmartAccessibilitySession.warmupTimeout)
        do {
            while true {
                try Task.checkCancellation()
                do {
                    let target = try capture(pid)
                    await reportManualAccessibility(accessibilitySession, pid: pid, outcome: "capture_ready")
                    return target
                } catch InputReplacementError.focusUnavailable where requested && ContinuousClock.now < deadline {
                    try await Task.sleep(for: FrozenSmartAccessibilitySession.warmupInterval)
                }
            }
        } catch InputReplacementError.focusUnavailable {
            await reportManualAccessibility(accessibilitySession, pid: pid, outcome: "focus_unavailable")
            throw InputReplacementError.focusUnavailable
        }
    }

    private func reportManualAccessibility(_ session: FrozenSmartAccessibilitySession, pid: pid_t, outcome: String) async {
        #if DEBUG || SEVEN_DEVELOPMENT
        guard let trace else { return }
        let state = await Task.detached(priority: .utility) { session.manualAccessibilityState(pid) }.value
        trace("manual.after.\(outcome).\(state)")
        #endif
    }

    private static func monitorInputDuringFocusRecovery(_ interrupt: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let start = ProcessInfo.processInfo.systemUptime
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            guard event.timestamp > start, !SelectionReader.isSynthetic(event) else { return }
            interrupt()
        }
        return { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    private func beginTranslation(target: any InputReplacementTargeting, id: UUID) {
        do {
            hud.begin(anchor: target.anchor) { [weak self] in self?.cancel() }
            let model = makeModel(); self.model = model
            if #available(macOS 15.0, *) {
                hud.installBridge(model: model)
                model.setSystemTranslationBridgeAvailable(true)
            }
            resultObserver = model.$serviceResults.sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.consume(id: id) }
            }
            _ = try model.beginInputReplacement(target.translationText)
            if let title = model.serviceResults.first?.title {
                hud.setServiceHint(title)
            }
        } catch { fail(error) }
    }

    func cancel() {
        // 写回及核验期间保留剪贴板租约和辅助功能会话。
        guard !writing else { return }
        clearSession()
        hud.close()
    }

    func terminate() {
        // 退出屏障取快照前登记辅助功能状态恢复。
        if writing {
            finishAccessibilitySession()
        } else {
            cancel()
        }
    }

    private func clearSession() {
        jobID = UUID()
        resultObserver = nil
        timeout?.cancel(); timeout = nil
        preparationTask?.cancel(); preparationTask = nil
        writeTask?.cancel(); writeTask = nil
        model?.cancel(); model = nil
        finishAccessibilitySession()
        target = nil; writing = false
    }

    private func finishAccessibilitySession() {
        accessibilitySession?.finish()
        accessibilitySession = nil
    }

    func refreshInterfaceLanguage() { hud.refreshInterfaceLanguage() }

    private func consume(id: UUID) {
        guard jobID == id, !writing, let model, let result = model.serviceResults.first else { return }
        guard !result.phase.isRunning, result.phase != .idle else { return }
        guard result.phase == .success, !result.text.isEmpty, let target else {
            fail(detail: result.issue ?? .key("translationDidNotFinishTheOriginalText"))
            return
        }
        writing = true
        hud.prepareForWrite()
        timeout?.cancel(); timeout = nil
        resultObserver = nil
        let translated = result.text
        writeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await target.replace(with: translated)
                guard jobID == id, !Task.isCancelled else { return }
                finish(.key("replaced"), success: true)
            } catch {
                guard jobID == id, !Task.isCancelled else { return }
                fail(error)
            }
        }
    }

    private func fail(_ error: Error, anchor: NSPoint? = nil) {
        if error as? SelectionReadError == .accessibilityPermission {
            writing = false
            clearSession()
            hud.close()
            authorize()
            return
        }
        if error as? InputReplacementError == .empty {
            writing = false
            clearSession()
            hud.close()
            return
        }
        if let anchor { hud.setAnchor(anchor) }
        let presentation = InputReplacementFailurePresentation(error: error)
        finish(presentation.reasonMessage, success: false, detail: presentation.detailMessage)
    }
    private func fail(detail: LocalizedMessage) {
        finish(.key("translationFailed"), success: false, detail: detail)
    }
    private func finish(_ message: LocalizedMessage, success: Bool, detail: LocalizedMessage? = nil) {
        writing = false
        clearSession()
        hud.detachBridge()
        hud.showResult(message, success: success, detail: detail)
        let id = jobID
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Design.ReplacementHUD.resultHold))
            guard !Task.isCancelled, let self, jobID == id else { return }
            hud.close()
        }
    }
}
