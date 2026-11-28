import AppKit
import os

/// Centrally retains all submitted restorations; after a screenshot closes, its task still participates in the app termination barrier.
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

    /// Callers must cancel all active screenshots before taking a snapshot; subsequent sessions must not enable AX mode.
    func beginTermination() -> Task<Void, Never> {
        let tasks = state.withLock { state in
            state.terminating = true
            return Array(state.tasks.values)
        }
        return Task.detached { for task in tasks { await task.value } }
    }
}

/// AppKit continues processing events and replies at most once when restoration completes or the grace period expires; never blocks synchronously waiting on AX.
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
        // Avoid a task group that waits for all child tasks: when AX is unresponsive, waiting for restoration may not be cancellable.
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
