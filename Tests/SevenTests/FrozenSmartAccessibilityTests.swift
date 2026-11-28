import ApplicationServices
import XCTest
import os
@testable import Seven

private struct SmartAccessibilityAttributesMock: FrozenSmartAccessibilityAttributes {
    struct Write: Equatable, Sendable {
        let pid: pid_t
        let attribute: FrozenSmartAccessibilityAttribute
        let value: Bool
    }
    struct State: Sendable {
        var values: [pid_t: [FrozenSmartAccessibilityAttribute: Bool]]
        var ignored: Set<FrozenSmartAccessibilityAttribute> = []
        var writes: [Write] = []
    }
    let storage: OSAllocatedUnfairLock<State>
    init(_ values: [pid_t: [FrozenSmartAccessibilityAttribute: Bool]], ignored: Set<FrozenSmartAccessibilityAttribute> = []) {
        storage = OSAllocatedUnfairLock(initialState: State(values: values, ignored: ignored))
    }
    func read(_ attribute: FrozenSmartAccessibilityAttribute, in pid: pid_t) -> Bool? { storage.withLock { $0.values[pid]?[attribute] } }
    func set(_ value: Bool, for attribute: FrozenSmartAccessibilityAttribute, in pid: pid_t) -> AXError {
        storage.withLock {
            $0.writes.append(.init(pid: pid, attribute: attribute, value: value))
            if !$0.ignored.contains(attribute), $0.values[pid]?[attribute] != nil { $0.values[pid]?[attribute] = value }
        }
        return .success
    }
    var writes: [Write] { storage.withLock { $0.writes } }
}

final class FrozenSmartAccessibilityTests: XCTestCase {
    func testManualModeIsRequestedOncePerProcessAndRestoredOnceAtEnd() async {
        let backend = SmartAccessibilityAttributesMock([1: [.manual: false, .enhanced: false]])
        let session = FrozenSmartAccessibilitySession(attributes: backend)
        XCTAssertTrue(session.prepare(1))
        XCTAssertTrue(backend.read(.manual, in: 1) == true)
        XCTAssertFalse(session.prepare(1))
        XCTAssertEqual(backend.writes, [.init(pid: 1, attribute: .manual, value: true)])
        await session.finish().value; await session.finish().value
        XCTAssertEqual(backend.writes, [.init(pid: 1, attribute: .manual, value: true), .init(pid: 1, attribute: .manual, value: false)])
        XCTAssertFalse(backend.read(.enhanced, in: 1) == true)
    }
    func testEnhancedModeFallbackUsesReadbackAndRestoresRuntimeState() async {
        // Simulates the native bridge: manual is unreadable; real state written to enhanced can be read back instead of relying on the setter return code.
        let backend = SmartAccessibilityAttributesMock([9: [.enhanced: false]])
        let session = FrozenSmartAccessibilitySession(attributes: backend)
        XCTAssertTrue(session.prepare(9))
        XCTAssertEqual(backend.writes, [.init(pid: 9, attribute: .enhanced, value: true)])
        await session.finish().value
        XCTAssertEqual(backend.read(.enhanced, in: 9), false)
        XCTAssertEqual(backend.writes.last, .init(pid: 9, attribute: .enhanced, value: false))
    }
    func testAlreadyEnabledModeIsNeverDisabledAndUnknownAttributesAreNotWritten() async {
        let backend = SmartAccessibilityAttributesMock([1: [.manual: true, .enhanced: false], 2: [.enhanced: true], 3: [:]])
        let session = FrozenSmartAccessibilitySession(attributes: backend)
        XCTAssertFalse(session.prepare(1)); XCTAssertFalse(session.prepare(2)); XCTAssertFalse(session.prepare(3))
        await session.finish().value
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertEqual(backend.read(.manual, in: 1), true)
        XCTAssertEqual(backend.read(.enhanced, in: 2), true)
    }
    func testFailedPreparationFallsBackWithoutClaimingWarmupAndFinishPreventsLateEnable() async {
        let backend = SmartAccessibilityAttributesMock([1: [.manual: false, .enhanced: false]], ignored: [.manual, .enhanced])
        let session = FrozenSmartAccessibilitySession(attributes: backend)
        XCTAssertFalse(session.prepare(1))
        XCTAssertEqual(backend.writes.count, 2)
        await session.finish().value
        XCTAssertFalse(session.prepare(2))
        XCTAssertEqual(backend.writes.count, 2, "取消后迟到查询不能再开启目标应用的AX模式")
    }
    func testChangedProcessesAreIndependentAndExternallyDisabledModeIsNotReenabledOnFinish() async {
        let backend = SmartAccessibilityAttributesMock([1: [.manual: false], 2: [.enhanced: false]])
        let session = FrozenSmartAccessibilitySession(attributes: backend)
        XCTAssertTrue(session.prepare(1)); XCTAssertTrue(session.prepare(2))
        _ = backend.set(false, for: .manual, in: 1)
        let before = backend.writes.count
        await session.finish().value
        XCTAssertEqual(backend.writes.count, before + 1)
        XCTAssertEqual(backend.read(.manual, in: 1), false)
        XCTAssertEqual(backend.read(.enhanced, in: 2), false)
    }

    func testFinishingAnUnpublishedManualModeCancelsThePendingEnable() async {
        let backend = SmartAccessibilityAttributesMock([1: [.manual: false]], ignored: [.manual])
        let session = FrozenSmartAccessibilitySession(attributes: backend, restorations: .init())
        XCTAssertTrue(session.requestManualAccessibility(1))
        XCTAssertEqual(backend.read(.manual, in: 1), false)

        await session.finish().value

        XCTAssertEqual(backend.writes, [
            .init(pid: 1, attribute: .manual, value: true), .init(pid: 1, attribute: .manual, value: false)
        ])
    }

    func testManualAccessibilityAlreadyEnabledDoesNotRequestWarmup() async {
        let backend = SmartAccessibilityAttributesMock([1: [.manual: true], 2: [.enhanced: false]])
        let session = FrozenSmartAccessibilitySession(attributes: backend, restorations: .init())

        XCTAssertFalse(session.requestManualAccessibility(1))
        XCTAssertFalse(session.requestManualAccessibility(2))
        await session.finish().value

        XCTAssertTrue(backend.writes.isEmpty)
    }
}

extension FrozenSmartAccessibilityTests {
    func testConcurrentPreparationAndFinishCannotLeaveModeEnabledOrReactivateSession() async {
        let backend = SmartAccessibilityAttributesMock([1: [.manual: false]])
        let session = FrozenSmartAccessibilitySession(attributes: backend)
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            if index % 4 == 0 { session.finish() }
            else { _ = session.prepare(1) }
        }
        await session.finish().value
        XCTAssertEqual(backend.read(.manual, in: 1), false)
        XCTAssertLessThanOrEqual(backend.writes.count, 2, "同一会话最多开启一次、恢复一次")
        let count = backend.writes.count
        XCTAssertFalse(session.prepare(1))
        XCTAssertEqual(backend.writes.count, count)
    }
}

/// Uses a semaphore to simulate an unresponsive external app without touching system AX or real apps.
private final class BlockingSmartAccessibilityMock: FrozenSmartAccessibilityAttributes, @unchecked Sendable {
    let backend = SmartAccessibilityAttributesMock([1: [.manual: false]])
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let blockNextRead = OSAllocatedUnfairLock(initialState: false)
    func block() { blockNextRead.withLock { $0 = true } }
    func read(_ attribute: FrozenSmartAccessibilityAttribute, in pid: pid_t) -> Bool? {
        let shouldBlock = blockNextRead.withLock { value in
            let previous = value; value = false; return previous
        }
        if shouldBlock {
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
        }
        return backend.read(attribute, in: pid)
    }
    func set(_ value: Bool, for attribute: FrozenSmartAccessibilityAttribute, in pid: pid_t) -> AXError {
        backend.set(value, for: attribute, in: pid)
    }
}

extension FrozenSmartAccessibilityTests {
    func testFinishingSessionDoesNotWaitForBlockedPreparation() async {
        let backend = BlockingSmartAccessibilityMock()
        let session = FrozenSmartAccessibilitySession(attributes: backend)
        backend.block()
        let prepared = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = session.prepare(1); prepared.signal() }
        XCTAssertEqual(backend.entered.wait(timeout: .now() + 1), .success)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { session.finish(); finished.signal() }
        let result = waitForSmartSignal(finished, timeout: 0.2)
        backend.release.signal()
        XCTAssertEqual(result, .success, "结束截图不能等待外部AX响应，否则最上层遮罩无法关闭")
        XCTAssertEqual(prepared.wait(timeout: .now() + 2), .success)
        if result != .success { XCTAssertEqual(finished.wait(timeout: .now() + 2), .success) }
        await session.finish().value
        XCTAssertEqual(backend.backend.read(.manual, in: 1), false)
        XCTAssertFalse(session.prepare(1))
    }

    func testNextSessionWaitsForPreviousRestorationBeforeEnablingMode() async {
        let backend = BlockingSmartAccessibilityMock()
        let first = FrozenSmartAccessibilitySession(attributes: backend)
        let second = FrozenSmartAccessibilitySession(attributes: backend)
        XCTAssertTrue(first.prepare(1))
        backend.block()
        first.finish()
        XCTAssertEqual(backend.entered.wait(timeout: .now() + 1), .success)
        let nextPrepared = DispatchSemaphore(value: 0)
        let enabled = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.global().async {
            let result = second.prepare(1)
            enabled.withLock { $0 = result }
            nextPrepared.signal()
        }
        let premature = waitForSmartSignal(nextPrepared, timeout: 0.1)
        backend.release.signal()
        XCTAssertEqual(premature, .timedOut, "新会话必须排在旧会话恢复之后，否则旧恢复会关闭新会话使用的AX模式")
        if premature == .timedOut { XCTAssertEqual(nextPrepared.wait(timeout: .now() + 2), .success) }
        await first.finish().value
        XCTAssertTrue(enabled.withLock { $0 })
        XCTAssertEqual(backend.backend.read(.manual, in: 1), true)
        await second.finish().value
        XCTAssertEqual(backend.backend.read(.manual, in: 1), false)
    }

    func testFinishingSessionDoesNotPerformBlockingRestorationOnCaller() async {
        let backend = BlockingSmartAccessibilityMock()
        let session = FrozenSmartAccessibilitySession(attributes: backend)
        XCTAssertTrue(session.prepare(1))
        backend.block()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { session.finish(); finished.signal() }
        XCTAssertEqual(backend.entered.wait(timeout: .now() + 1), .success)
        let result = waitForSmartSignal(finished, timeout: 0.2)
        backend.release.signal()
        XCTAssertEqual(result, .success, "恢复外部应用AX状态不能阻塞截图结束的调用线程")
        if result != .success { XCTAssertEqual(finished.wait(timeout: .now() + 2), .success) }
        await session.finish().value
        XCTAssertEqual(backend.backend.read(.manual, in: 1), false)
    }
}

private func waitForSmartSignal(_ signal: DispatchSemaphore, timeout: TimeInterval) -> DispatchTimeoutResult {
    signal.wait(timeout: .now() + timeout)
}
