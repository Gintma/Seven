import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Seven

@MainActor
final class OnboardingGuideOwnershipTests: XCTestCase {
    private final class Tracker: PermissionWindowTracking {
        var onFrameChange: ((CGRect) -> Void)?
        var onSettingsClosed: (() -> Void)?
        var onPoll: (() -> Void)?
        var started = XCTestExpectation(description: "开始跟踪系统设置")
        var running = false
        func start() { running = true; started.fulfill() }
        func stop() { running = false }
    }

    private enum Exit: CaseIterable { case start, closeButton, escape }

    func testStartCloseAndEscapeStopTheOnboardingPermissionGuide() async throws {
        for exit in Exit.allCases {
            try await exercise(exit, otherEntryTakesOver: false)
        }
    }

    func testOnboardingExitPreservesAReplacementGuideForTheSamePermission() async throws {
        for exit in Exit.allCases {
            try await exercise(exit, otherEntryTakesOver: true)
        }
    }

    private func exercise(_ exit: Exit, otherEntryTakesOver: Bool) async throws {
        _ = NSApplication.shared
        let tracker = Tracker()
        let guide = PermissionGuide(tracker: tracker, openPane: { _ in true }, isGranted: { _ in false })
        defer { guide.close() }
        let defaults = try XCTUnwrap(isolatedDefaults())
        let flow = OnboardingFlow(defaults: defaults, hasExistingUsage: false)
        XCTAssertTrue(flow.shouldShow(hasPendingImages: false))
        let window = OnboardingWindowController.makeWindow()
        var events: [String] = []
        let controller = OnboardingWindowController(flow: flow, window: window, permissionGuide: guide,
            openInput: { events.append("input") }, didClose: { events.append("close") })

        controller.authorize(.accessibility)
        await fulfillment(of: [tracker.started], timeout: 2)
        if otherEntryTakesOver {
            tracker.started = XCTestExpectation(description: "其他入口重新开始跟踪")
            guide.authorize(.accessibility)
            await fulfillment(of: [tracker.started], timeout: 2)
        }
        XCTAssertTrue(tracker.running)
        switch exit {
        case .start: controller.startUsing()
        case .closeButton: window.performClose(nil)
        case .escape:
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: UInt16(kVK_Escape)))
            window.sendEvent(event)
        }
        XCTAssertEqual(events, exit == .start ? ["close", "input"] : ["close"], "\(exit)")
        XCTAssertEqual(tracker.running, otherEntryTakesOver, "\(exit): 权限浮窗应随其所有者关闭")
    }
}
