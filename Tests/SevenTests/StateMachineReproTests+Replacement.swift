import AppKit
import XCTest
@testable import Seven

@MainActor private final class ReproReplacementTarget: InputReplacementTargeting {
    let snapshot: InputReplacementSnapshot
    let anchor: NSPoint?
    let preparationError: InputReplacementError?

    init(anchor: NSPoint, preparationError: InputReplacementError? = nil) throws {
        snapshot = try InputReplacementSnapshot(value: "Hello world", range: NSRange(location: 0, length: 0))
        self.anchor = anchor
        self.preparationError = preparationError
    }

    func prepare() async throws {
        if let preparationError { throw preparationError }
    }

    func replace(with text: String) async throws {}
}

extension StateMachineReproTests {
    func testRepro07_earlyFailureUsesCurrentLocationInsteadOfPreviousHUDAnchor() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let previous = NSPoint(x: screen.minX + 40, y: screen.minY + 70)
        let current = NSPoint(x: previous.x, y: screen.midY)
        let hud = InputReplacementHUD(mouseLocation: { current })
        let gate = ReproGate()
        let model = try model(service: ReproService { _, _ in
            await gate.pause()
            return "完整译文"
        })
        try addService("A", to: model)
        let target = try ReproReplacementTarget(anchor: previous)
        let rejectedAnchor = NSPoint(x: current.x, y: current.y + 40)
        let rejectedTarget = try ReproReplacementTarget(anchor: rejectedAnchor, preparationError: .readOnly)
        let coordinator = InputReplacementCoordinator(capture: { pid in
            if pid == 1 { return target }
            if pid == 3 { return rejectedTarget }
            throw InputReplacementError.readOnly
        }, authorize: {}, hud: hud, makeModel: { model })
        defer { coordinator.cancel(); gate.release() }

        coordinator.start(pid: 1)
        try await reached("第一笔替换已开始翻译", until: { gate.entered })
        XCTAssertEqual(hud.panel.frame.minY, previous.y, accuracy: 1)
        coordinator.start(pid: 2)

        XCTAssertEqual(hud.panel.contentView?.toolTip, InputReplacementError.readOnly.issue.text)
        XCTAssertEqual(hud.panel.frame.minY, current.y, accuracy: 1)

        coordinator.start(pid: 3)
        try await reached("当前目标准备失败后显示 HUD", until: { hud.panel.isVisible })
        XCTAssertEqual(hud.panel.contentView?.toolTip, InputReplacementError.readOnly.issue.text)
        XCTAssertEqual(hud.panel.frame.minY, rejectedAnchor.y, accuracy: 1)
    }
}
