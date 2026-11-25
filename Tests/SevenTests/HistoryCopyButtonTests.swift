import AppKit
import SwiftUI
import XCTest
@testable import Seven

final class HistoryCopyButtonTests: XCTestCase {
    @MainActor
    func testCopyConfirmsInPlaceWithoutMovingNeighboringAction() async throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let host = NSHostingView(rootView: HStack {
            HistoryCopyButton(text: "First fixture", label: "Copy source", pasteboard: pasteboard)
            HistoryCopyButton(text: "Second fixture", label: "Copy result", pasteboard: pasteboard)
        })
        host.setFrameSize(NSSize(width: 200, height: 60))
        host.layoutSubtreeIfNeeded()

        func buttons(in view: NSView) -> [AnimatedSymbolButton] {
            if let button = view as? AnimatedSymbolButton { return [button] }
            return view.subviews.flatMap { buttons(in: $0) }
        }
        let actions = buttons(in: host)
        let source = try XCTUnwrap(actions.first { $0.toolTip == "Copy source" })
        let result = try XCTUnwrap(actions.first { $0.toolTip == "Copy result" })
        func frames() -> [NSRect] {
            [source, result].map { $0.convert($0.bounds, to: host) }
        }

        let before = frames()
        source.performClick(nil)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(pasteboard.string(forType: .string), "First fixture")
        XCTAssertTrue(source.isShowingConfirmation)
        XCTAssertFalse(result.isShowingConfirmation)
        XCTAssertEqual(frames(), before)

        for _ in 0..<100 where source.isShowingConfirmation {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(source.isShowingConfirmation)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(frames(), before)
    }
}
