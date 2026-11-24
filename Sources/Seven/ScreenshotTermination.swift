import AppKit
import os

/// 集中保留所有已提交的恢复；截图关闭后任务仍属于应用退出屏障。
final class FrozenSmartAccessibilityRestorations: Sendable {
    static let shared = FrozenSmartAccessibilityRestorations()
    private struct State: Sendable {
        var tasks: [UUID: Task<Void, Never>] = [:]
        var terminating = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var isTerminating: Bool { state.withLock { $0.terminating } }

    func track(_ task: Task<Void, Never>) {
        let id = UUID()
        state.withLock { $0.tasks[id] = task }
        Task.detached { [self] in
            await task.value
            state.withLock { $0.tasks[id] = nil }
        }
    }

    /// 调用方先取消所有当前截图，再取快照；之后的新会话不得开启AX模式。
    func beginTermination() -> Task<Void, Never> {
        let tasks = state.withLock { state in
            state.terminating = true
            return Array(state.tasks.values)
        }
        return Task.detached { for task in tasks { await task.value } }
    }
}

/// AppKit继续处理事件，恢复完成或宽限到期时仅回复一次；不同步等待AX。
@MainActor
final class ScreenshotTerminationCoordinator {
    nonisolated static let gracePeriod: Duration = .seconds(2)
    private enum Phase { case idle, waiting, ready }
    private var phase = Phase.idle
    private var timeout: Task<Void, Never>?
    private let restorations: FrozenSmartAccessibilityRestorations
    private let gracePeriod: Duration
    private let reply: @MainActor (Bool) -> Void

    init(restorations: FrozenSmartAccessibilityRestorations = .shared,
         gracePeriod: Duration = ScreenshotTerminationCoordinator.gracePeriod,
         reply: @escaping @MainActor (Bool) -> Void) {
        self.restorations = restorations
        self.gracePeriod = gracePeriod
        self.reply = reply
    }

    func requestTermination(cancelCapture: () -> Void) -> NSApplication.TerminateReply {
        switch phase {
        case .waiting: return .terminateLater
        case .ready: return .terminateNow
        case .idle: break
        }
        phase = .waiting
        let deadline = ContinuousClock.now.advanced(by: gracePeriod)
        cancelCapture()
        let barrier = restorations.beginTermination()
        Task { [weak self] in
            await barrier.value
            self?.complete()
        }
        // 不使用等待全部子任务的task group：AX无响应时，恢复等待可能无法取消。
        timeout = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            self?.complete()
        }
        return .terminateLater
    }

    private func complete() {
        guard phase == .waiting else { return }
        phase = .ready
        timeout?.cancel(); timeout = nil
        reply(true)
    }
}
