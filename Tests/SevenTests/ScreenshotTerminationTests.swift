import ApplicationServices
import AppKit
import XCTest
import os
@testable import Seven

/// Blocks only on the restore read operation; all properties are stored in memory.
private final class TerminationAccessibilityMock: FrozenSmartAccessibilityAttributes, @unchecked Sendable {
    private let restoring = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let state = OSAllocatedUnfairLock(initialState: (enabled: false, block: false))
    func read(_ attribute: FrozenSmartAccessibilityAttribute, in pid: pid_t) -> Bool? {
        guard attribute == .manual else { return nil }
        let block = state.withLock { value in
            let block = value.block; value.block = false; return block
        }
        if block {
            restoring.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        return state.withLock { $0.enabled }
    }
    func set(_ value: Bool, for attribute: FrozenSmartAccessibilityAttribute, in pid: pid_t) -> AXError {
        state.withLock { $0.enabled = value }
        return .success
    }
    func blockRestoration() { state.withLock { $0.block = true } }
    func waitUntilRestoring() -> DispatchTimeoutResult { restoring.wait(timeout: .now() + 1) }
    var isEnabled: Bool { state.withLock { $0.enabled } }
}

final class ScreenshotTerminationTests: XCTestCase {
    @MainActor
    func testApplicationDefersTerminationWhileAlreadyClosedSessionRestores() async throws {
        let restorations = FrozenSmartAccessibilityRestorations()
        let backend = TerminationAccessibilityMock()
        let session = FrozenSmartAccessibilitySession(attributes: backend, restorations: restorations)
        let prepared = await Task.detached { session.prepare(1) }.value
        XCTAssertTrue(prepared)
        backend.blockRestoration()
        // Screenshot capture was already closed, and the caller did not retain the task returned by finish.
        session.finish()
        let entered = await Task.detached { backend.waitUntilRestoring() }.value
        XCTAssertEqual(entered, .success)
        defer { backend.release.signal() }
        let replied = expectation(description: "恢复完成后回复 AppKit")
        var replies: [Bool] = []
        let appDelegate = AppDelegate()
        appDelegate.screenshotTermination = ScreenshotTerminationCoordinator(restorations: restorations) {
            replies.append($0); replied.fulfill()
        }
        let delegate: any NSApplicationDelegate = appDelegate
        let decision = delegate.applicationShouldTerminate?(NSApplication.shared) ?? .terminateNow
        XCTAssertEqual(decision, .terminateLater, "已关闭截图的恢复仍被阻塞时，退出必须先延期")
        XCTAssertEqual(delegate.applicationShouldTerminate?(NSApplication.shared), .terminateLater)
        // Restoration is still blocked while MainActor can proceed; must not reply early.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(replies.isEmpty)
        XCTAssertTrue(backend.isEnabled)
        backend.release.signal()
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(replies, [true])
        XCTAssertFalse(backend.isEnabled)
        XCTAssertEqual(delegate.applicationShouldTerminate?(NSApplication.shared), .terminateNow)
    }

    @MainActor
    func testApplicationAllowsTerminationAtGraceDeadlineWhileRestorationIsBlocked() async throws {
        let restorations = FrozenSmartAccessibilityRestorations()
        let backend = TerminationAccessibilityMock()
        let session = FrozenSmartAccessibilitySession(attributes: backend, restorations: restorations)
        let prepared = await Task.detached { session.prepare(1) }.value
        XCTAssertTrue(prepared)
        backend.blockRestoration()
        let restoration = session.finish()
        let entered = await Task.detached { backend.waitUntilRestoring() }.value
        XCTAssertEqual(entered, .success)
        defer { backend.release.signal() }
        let replied = expectation(description: "到达宽限上限后放行退出")
        var replies: [Bool] = []
        let appDelegate = AppDelegate()
        appDelegate.screenshotTermination = ScreenshotTerminationCoordinator(
            restorations: restorations, gracePeriod: .milliseconds(80)
        ) { replies.append($0); replied.fulfill() }
        let started = ContinuousClock.now
        XCTAssertEqual(appDelegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        await fulfillment(of: [replied], timeout: 1)
        let elapsed = started.duration(to: .now)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(80))
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(replies, [true])
        XCTAssertTrue(backend.isEnabled, "超时放行并不代表阻塞中的恢复已经完成")
        backend.release.signal()
        await restoration.value
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(replies, [true], "超时后恢复完成不得重复回复退出")
        XCTAssertFalse(backend.isEnabled)
        let lateSession = FrozenSmartAccessibilitySession(attributes: backend, restorations: restorations)
        let latePrepared = await Task.detached { lateSession.prepare(1) }.value
        XCTAssertFalse(latePrepared, "退出屏障建立后，新会话不得再开启 AX 模式")
        await lateSession.finish().value
    }

    @MainActor
    func testTerminationCancelsActiveSessionsBeforeWaitingForAllQueuedRestorations() async throws {
        let restorations = FrozenSmartAccessibilityRestorations()
        let firstBackend = TerminationAccessibilityMock()
        let secondBackend = TerminationAccessibilityMock()
        let first = FrozenSmartAccessibilitySession(attributes: firstBackend, restorations: restorations)
        let second = FrozenSmartAccessibilitySession(attributes: secondBackend, restorations: restorations)
        let prepared = await Task.detached { [first.prepare(1), second.prepare(2)] }.value
        XCTAssertEqual(prepared, [true, true])
        firstBackend.blockRestoration(); secondBackend.blockRestoration()
        defer { firstBackend.release.signal(); secondBackend.release.signal() }
        let replied = expectation(description: "全部排队恢复完成后放行")
        var replies: [Bool] = []
        var cancellations = 0
        let coordinator = ScreenshotTerminationCoordinator(restorations: restorations) {
            replies.append($0); replied.fulfill()
        }
        let decision = coordinator.requestTermination {
            cancellations += 1
            first.finish(); second.finish()
        }
        XCTAssertEqual(decision, .terminateLater)
        XCTAssertEqual(cancellations, 1)
        let firstEntered = await Task.detached { firstBackend.waitUntilRestoring() }.value
        XCTAssertEqual(firstEntered, .success)
        XCTAssertTrue(replies.isEmpty)
        firstBackend.release.signal()
        let secondEntered = await Task.detached { secondBackend.waitUntilRestoring() }.value
        XCTAssertEqual(secondEntered, .success)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(replies.isEmpty, "第一个恢复完成不能越过队列中剩余的恢复")
        secondBackend.release.signal()
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(replies, [true])
        XCTAssertFalse(firstBackend.isEnabled); XCTAssertFalse(secondBackend.isEnabled)
        XCTAssertEqual(coordinator.requestTermination { cancellations += 1 }, .terminateNow)
        XCTAssertEqual(cancellations, 1)
    }

    @MainActor
    func testTerminationWithoutPendingRestorationsRepliesAsynchronouslyOnce() async throws {
        let replied = expectation(description: "无恢复任务时及时回复")
        var replies: [Bool] = []
        let coordinator = ScreenshotTerminationCoordinator(
            restorations: FrozenSmartAccessibilityRestorations(), gracePeriod: .milliseconds(30)
        ) { replies.append($0); replied.fulfill() }
        XCTAssertEqual(coordinator.requestTermination {}, .terminateLater)
        XCTAssertTrue(replies.isEmpty, "必须先向 AppKit 返回 terminateLater，再回复")
        await fulfillment(of: [replied], timeout: 1)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(replies, [true], "成功路径应取消超时回复")
    }
}
