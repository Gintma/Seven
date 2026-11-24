import AppKit
import SceneKit
import XCTest
@testable import Seven

final class OnboardingMascotLifecycleTests: XCTestCase {
    @MainActor func testIdleTiltCanYieldToPointerAndExpressions() throws {
        let portrait = ShibaPortrait()
        let view = try XCTUnwrap(portrait.makeView())
        let pivot = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "nodPivot", recursively: true))
        portrait.tilt(1)
        XCTAssertNotNil(pivot.action(forKey: "idleTilt"))
        portrait.stopIdleTilt()
        XCTAssertNil(pivot.action(forKey: "idleTilt"))
        XCTAssertNotNil(pivot.action(forKey: "settle"))
        portrait.cancelExpression()
        XCTAssertFalse(pivot.hasActions)
        XCTAssertEqual(pivot.eulerAngles.z, 0, accuracy: 0.001)
    }

    @MainActor func testIdleTaskFinishesWhenMascotIsReleasedWithoutWindowCallbacks() async {
        weak var releasedMascot: OnboardingMascotView?
        let task = autoreleasepool {
            let mascot = OnboardingMascotView(icon: NSImage(size: .zero))
            releasedMascot = mascot
            return mascot.makeIdleTask()
        }
        defer { task.cancel() }
        XCTAssertNil(releasedMascot)

        let finished = expectation(description: "待机任务随视图释放而结束")
        Task {
            await task.value
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 4)
    }
}
