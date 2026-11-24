import AppKit
import XCTest
@testable import Seven

private final class SmartTreeMock: FrozenSmartTreeReading {
    struct Item {
        var role: String
        var frame: CGRect
        var children: [Int] = []
    }
    var items: [Int: Item]
    var roots: [Int]
    var pointed: Int?
    var readNodes: Set<Int> = []
    init(_ items: [Int: Item], roots: [Int] = [1], pointed: Int? = nil) {
        self.items = items; self.roots = roots; self.pointed = pointed
    }
    func windows() -> [Int] { roots }
    func hit(at point: CGPoint) -> Int? { pointed }
    func role(_ node: Int) -> String? { readNodes.insert(node); return items[node]?.role }
    func frame(_ node: Int) -> CGRect? { items[node]?.frame }
    func children(_ node: Int) -> [Int] { items[node]?.children ?? [] }
    func parent(_ node: Int) -> Int? { items.first { $0.value.children.contains(node) }?.key }
}

final class FrozenSmartTreeTests: XCTestCase {
    private let window = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let panel = CGRect(x: 200, y: 200, width: 300, height: 250)
    private let button = CGRect(x: 300, y: 300, width: 100, height: 40)
    private let point = CGPoint(x: 350, y: 320)

    func testCoordinateHitOnOwnScreenshotOverlayIsReplacedByOriginalWindowTree() {
        let overlay = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let reader = SmartTreeMock([
            9: .init(role: "AXWindow", frame: overlay),
            1: .init(role: "AXWindow", frame: window, children: [2]),
            2: .init(role: "AXGroup", frame: panel, children: [3]),
            3: .init(role: "AXButton", frame: button)
        ], roots: [9, 1], pointed: 9)
        let path = FrozenSmartTree(reader: reader).query(at: point, in: window).ancestry
        XCTAssertEqual(FrozenSmartRegion.selection(at: point, in: window, ancestry: path), button)
        XCTAssertTrue(path.contains { $0.frame == panel })
        XCTAssertFalse(path.contains { $0.frame == overlay })
    }
    func testContainerHitDescendsToControlRatherThanStoppingAtPanel() {
        let reader = SmartTreeMock([
            1: .init(role: "AXWindow", frame: window, children: [2]),
            2: .init(role: "AXGroup", frame: panel, children: [3]),
            3: .init(role: "AXTextField", frame: button)
        ], pointed: 2)
        let path = FrozenSmartTree(reader: reader).query(at: point, in: window).ancestry
        XCTAssertEqual(FrozenSmartRegion.selection(at: point, in: window, ancestry: path), button)
    }
    func testEmptyHitBranchRechecksOriginalWindowAndFindsSiblingRows() {
        let lower = CGRect(x: 300, y: 419, width: 100, height: 36)
        let upper = CGRect(x: 300, y: 455, width: 100, height: 36)
        let reader = SmartTreeMock([
            1: .init(role: "AXWindow", frame: window, children: [2, 9]),
            2: .init(role: "AXGroup", frame: CGRect(x: 200, y: 200, width: 300, height: 350), children: [3, 4]),
            3: .init(role: "AXButton", frame: lower),
            4: .init(role: "AXButton", frame: upper),
            9: .init(role: "AXGroup", frame: window)
        ], pointed: 9)
        let location = CGPoint(x: 350, y: 454.75)
        let result = FrozenSmartTree(reader: reader).query(at: location, in: window)
        XCTAssertEqual(FrozenSmartRegion.selection(at: location, in: window, ancestry: result.ancestry), lower)
        XCTAssertTrue(result.siblings.contains { $0.frame == upper })
        var cache = FrozenSmartSelectionCache()
        let candidate = FrozenWindowCandidate(id: 1, frame: window)
        _ = cache.target(at: location, in: candidate, result: result)
        XCTAssertEqual(cache.element(at: CGPoint(x: 350, y: 455.25), in: candidate)?.frame, upper)
    }
    func testMissingOriginalWindowNeverUsesUnrelatedWindow() {
        let reader = SmartTreeMock([1: .init(role: "AXWindow", frame: CGRect(x: 1000, y: 0, width: 800, height: 600))], pointed: 1)
        XCTAssertTrue(FrozenSmartTree(reader: reader).query(at: point, in: window).ancestry.isEmpty)
    }
    func testSiblingPrefetchExcludesRowsOutsideScrollViewport() {
        let viewport = CGRect(x: 100, y: 100, width: 200, height: 100)
        let visible = CGRect(x: 100, y: 110, width: 200, height: 30)
        let hidden = CGRect(x: 100, y: 350, width: 200, height: 30)
        let reader = SmartTreeMock([
            1: .init(role: "AXWindow", frame: window, children: [2]),
            2: .init(role: "AXScrollArea", frame: viewport, children: [3]),
            3: .init(role: "AXOutline", frame: CGRect(x: 100, y: 100, width: 200, height: 500), children: [4, 5]),
            4: .init(role: "AXRow", frame: visible),
            5: .init(role: "AXRow", frame: hidden)
        ], pointed: 4)
        let result = FrozenSmartTree(reader: reader).query(at: CGPoint(x: 150, y: 120), in: window)
        XCTAssertTrue(result.siblings.contains { $0.frame == visible })
        XCTAssertFalse(result.siblings.contains { $0.frame == hidden })
    }
    func testButtonOwnsItsImageAndStandaloneImageIsSelectable() {
        let image = CGRect(x: 330, y: 310, width: 16, height: 16)
        let location = CGPoint(x: 335, y: 315)
        let reader = SmartTreeMock([
            1: .init(role: "AXWindow", frame: window, children: [2]),
            2: .init(role: "AXButton", frame: button, children: [3]),
            3: .init(role: "AXImage", frame: image)
        ], pointed: 3)
        var path = FrozenSmartTree(reader: reader).query(at: location, in: window).ancestry
        XCTAssertEqual(FrozenSmartRegion.selection(at: location, in: window, ancestry: path), button)
        reader.items[1]?.children = [3]; reader.items.removeValue(forKey: 2)
        path = FrozenSmartTree(reader: reader).query(at: location, in: window).ancestry
        XCTAssertEqual(FrozenSmartRegion.selection(at: location, in: window, ancestry: path), image)
    }
    func testTextRowIsNotDiscardedAndStandaloneTextRemainsSelectable() {
        let row = CGRect(x: 210, y: 250, width: 270, height: 23)
        let text = CGRect(x: 220, y: 253, width: 200, height: 17)
        let reader = SmartTreeMock([
            1: .init(role: "AXWindow", frame: window, children: [2]),
            2: .init(role: "AXGroup", frame: panel, children: [3]),
            3: .init(role: "AXGroup", frame: row, children: [4]),
            4: .init(role: "AXStaticText", frame: text)
        ], pointed: 4)
        let location = CGPoint(x: 250, y: 260)
        let path = FrozenSmartTree(reader: reader).query(at: location, in: window).ancestry
        XCTAssertTrue(path.contains { $0.frame == row })
        XCTAssertEqual(FrozenSmartRegion.selection(at: location, in: window, ancestry: path), text)
    }
    func testSettingsCellSelectsRowAndDoesNotExpandToSidebar() {
        let cell = CGRect(x: 89, y: 630, width: 178, height: 32)
        let row = CGRect(x: 79, y: 630, width: 198, height: 32)
        let viewport = CGRect(x: 79, y: 127, width: 215, height: 627)
        let target = CGRect(x: 71, y: 119, width: 723, height: 733)
        let path = [FrozenSmartRegion(role: "AXCell", frame: cell), .init(role: "AXRow", frame: row),
            .init(role: "AXOutline", frame: CGRect(x: 78, y: 164, width: 200, height: 1109)),
            .init(role: "AXScrollArea", frame: viewport), .init(role: "AXWindow", frame: target)]
        XCTAssertEqual(FrozenSmartRegion.selection(at: CGPoint(x: 100, y: 645), in: target, ancestry: path), row)
    }
    func testCellAndItsParentAreNotMistakenForTwoSiblingRows() {
        let first = CGRect(x: 100, y: 200, width: 200, height: 32)
        let second = CGRect(x: 100, y: 232, width: 200, height: 32)
        let reader = SmartTreeMock([
            1: .init(role: "AXWindow", frame: window, children: [2]),
            2: .init(role: "AXOutline", frame: CGRect(x: 100, y: 100, width: 200, height: 400), children: [3, 5]),
            3: .init(role: "AXRow", frame: first, children: [4]),
            4: .init(role: "AXCell", frame: first.insetBy(dx: 10, dy: 0)),
            5: .init(role: "AXRow", frame: second)
        ], pointed: 4)
        let result = FrozenSmartTree(reader: reader).query(at: CGPoint(x: 150, y: 210), in: window)
        XCTAssertTrue(result.siblings.contains { $0.role == "AXRow" && $0.frame == second })
    }
    func testOrdinaryGroupKeepsFullInputBorderAndScrollViewportClipsIt() {
        let field = CGRect(x: 88, y: 762, width: 197, height: 30)
        let group = CGRect(x: 89, y: 763, width: 195, height: 28)
        let target = CGRect(x: 71, y: 119, width: 723, height: 733)
        let path = [FrozenSmartRegion(role: "AXTextField", frame: field), .init(role: "AXGroup", frame: group)]
        XCTAssertEqual(FrozenSmartRegion.selection(at: CGPoint(x: 160, y: 775), in: target, ancestry: path), field)
        XCTAssertEqual(FrozenSmartRegion.selection(at: CGPoint(x: 160, y: 775), in: target,
            ancestry: [path[0], .init(role: "AXScrollArea", frame: group)]), field.intersection(group))
        let reader = SmartTreeMock([
            1: .init(role: "AXWindow", frame: target, children: [2]),
            2: .init(role: "AXGroup", frame: group, children: [3]),
            3: .init(role: "AXTextField", frame: field)
        ], pointed: 1)
        let borderPoint = CGPoint(x: 88.5, y: 775)
        let result = FrozenSmartTree(reader: reader).query(at: borderPoint, in: target).ancestry
        XCTAssertEqual(FrozenSmartRegion.selection(at: borderPoint, in: target, ancestry: result), field)
    }
    func testParentCacheCoversGapsAndIsIsolatedByWindow() {
        var cache = FrozenSmartSelectionCache()
        let candidate = FrozenWindowCandidate(id: 1, frame: window)
        let control = FrozenSmartRegion(role: "AXButton", frame: button)
        let path = [control, .init(role: "AXGroup", frame: panel), .init(role: "AXWindow", frame: window)]
        XCTAssertEqual(cache.target(at: point, in: candidate, result: .init(ancestry: path))?.frame, button)
        let gap = CGPoint(x: 250, y: 250)
        XCTAssertEqual(cache.target(at: gap, in: candidate, result: .init(ancestry: [.init(role: "AXWindow", frame: window)]))?.frame, panel)
        XCTAssertEqual(cache.target(at: point, in: candidate, result: .init(), retaining: control)?.frame, button)
        XCTAssertEqual(cache.target(at: gap, in: candidate, result: .init(), retaining: control)?.frame, panel)
        XCTAssertNil(cache.target(at: gap, in: .init(id: 2, frame: window), result: .init()))
        XCTAssertNil(cache.target(at: CGPoint(x: 100, y: 100), in: candidate, result: .init()))
    }
    func testKnownControlsRequireSameWindowBoundsAndProcess() {
        var cache = FrozenSmartSelectionCache()
        let original = FrozenWindowCandidate(id: 1, frame: window, ownerPID: 10)
        let control = FrozenSmartRegion(role: "AXButton", frame: button)
        _ = cache.target(at: point, in: original, result: .init(ancestry: [control]))
        let moved = FrozenWindowCandidate(id: 1, frame: window.offsetBy(dx: 20, dy: 0), ownerPID: 10)
        XCTAssertNil(cache.element(at: point, in: moved))
        XCTAssertNil(cache.target(at: point, in: moved, result: .init(), retaining: control))
        let otherProcess = FrozenWindowCandidate(id: 1, frame: moved.frame, ownerPID: 20)
        XCTAssertNil(cache.element(at: point, in: otherProcess))
    }
    func testDeepAncestryIsNotCutAtTwelveAndCyclesRemainBounded() {
        var nodes: [Int: SmartTreeMock.Item] = [1: .init(role: "AXWindow", frame: window, children: [2])]
        for id in 2...22 { nodes[id] = .init(role: "AXGroup", frame: window, children: [id + 1]) }
        nodes[23] = .init(role: "AXButton", frame: button)
        let reader = SmartTreeMock(nodes, pointed: 23)
        let path = FrozenSmartTree(reader: reader).query(at: point, in: window).ancestry
        XCTAssertEqual(FrozenSmartRegion.selection(at: point, in: window, ancestry: path), button)
        reader.items[23] = .init(role: "AXGroup", frame: window, children: [2])
        reader.pointed = nil
        var checks = 0
        _ = FrozenSmartTree(reader: reader).query(at: point, in: window, withinBudget: { checks += 1; return checks < 300 })
        XCTAssertLessThanOrEqual(reader.readNodes.count, 23)
    }
}
