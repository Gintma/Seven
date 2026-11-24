import AppKit
import XCTest
@testable import Seven

final class OnboardingMascotLifecycleTests: XCTestCase {
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
