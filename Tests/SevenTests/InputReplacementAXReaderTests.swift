import ApplicationServices
import XCTest
@testable import Seven

final class InputReplacementAXReaderTests: XCTestCase {
    func testRichEditorWithoutSelectedTextRangePreservesTheSelectedOccurrence() throws {
        let reader = makeRichEditorReader(selection: NSRange(location: 8, length: 5))

        let snapshot = try reader.read()

        XCTAssertEqual(snapshot.value, "hello 🥝hello")
        XCTAssertEqual(snapshot.range, NSRange(location: 8, length: 5))
        XCTAssertEqual(snapshot.text, "hello")
        XCTAssertEqual(snapshot.replacing(with: "你好"), "hello 🥝你好")
    }

    func testRichEditorWithCollapsedTextMarkerRangeIdentifiesWholeInput() throws {
        let reader = makeRichEditorReader(selection: NSRange(location: 8, length: 0))

        let snapshot = try reader.read()

        XCTAssertTrue(snapshot.replacesWholeInput)
        XCTAssertEqual(snapshot.range, NSRange(location: 8, length: 0))
        XCTAssertEqual(snapshot.text, "hello 🥝hello")
    }

    func testTextMarkerSelectionOutsideTheFocusedFieldRemainsUnreadable() {
        let reader = makeRichEditorReader(selection: NSRange(location: 13, length: 1))

        XCTAssertThrowsError(try reader.read()) { XCTAssertEqual($0 as? InputReplacementError, .unreadable) }
    }

    func testBackwardTextMarkerSelectionUsesTheSameRange() throws {
        let reader = makeRichEditorReader(selection: NSRange(location: 8, length: 5), backwards: true)

        XCTAssertEqual(try reader.read().range, NSRange(location: 8, length: 5))
    }

    @MainActor
    func testNativeSelectAllMustCoverTheWholeTextMarkerDocument() async throws {
        let original = try makeRichEditorReader(selection: NSRange(location: 8, length: 0)).read()
        let partial = try makeRichEditorReader(selection: NSRange(location: 8, length: 5)).read()
        let all = try makeRichEditorReader(selection: NSRange(location: 0, length: 13)).read()
        var current = original
        do {
            try await InputReplacementSelection.selectWholeInput(original: original, read: { current },
                checkTarget: {}, selectAll: { current = partial })
            XCTFail("整框翻译必须核验全选范围")
        } catch {
            XCTAssertEqual(error as? InputReplacementError, .selectionUnavailable)
        }
        current = original
        let selected = try await InputReplacementSelection.selectWholeInput(original: original, read: { current },
            checkTarget: {}, selectAll: { current = all })
        XCTAssertEqual(selected.text, "hello 🥝hello")
    }

    private func makeRichEditorReader(selection: NSRange, backwards: Bool = false) -> InputReplacementAXReader {
        // Simulates a node inside page body content where fixed selection coordinates must be relative to the editor origin.
        let before = "Outside "
        let field = "hello 🥝hello"
        let document = (before + field + " outside") as NSString
        let start = (before as NSString).length
        let end = start + (field as NSString).length
        let element = AXUIElementCreateApplication(1)
        return InputReplacementAXReader(element: element, attribute: { name in
            switch name {
            case kAXValueAttribute: return field as CFString
            case "AXSelectedTextMarkerRange":
                let first = start + selection.location
                let last = start + NSMaxRange(selection)
                return backwards ? Self.markerRange(last, first) : Self.markerRange(first, last)
            default: return nil
            }
        }, parameterized: { name, parameter in
            switch name {
            case "AXTextMarkerRangeForUIElement":
                XCTAssertTrue(CFEqual(parameter, element))
                return Self.markerRange(start, end)
            case "AXUIElementForTextMarker":
                let marker = unsafeBitCast(parameter, to: AXTextMarker.self)
                return (start...end).contains(Self.offset(marker)) ? element : nil
            case "AXTextMarkerRangeForUnorderedTextMarkers":
                guard let markers = parameter as? [AXTextMarker], markers.count == 2 else { return nil }
                let offsets = markers.map(Self.offset).sorted()
                return Self.markerRange(offsets[0], offsets[1])
            case "AXStringForTextMarkerRange":
                guard CFGetTypeID(parameter) == AXTextMarkerRangeGetTypeID() else { return nil }
                let range = unsafeBitCast(parameter, to: AXTextMarkerRange.self)
                let first = Self.offset(AXTextMarkerRangeCopyStartMarker(range))
                let last = Self.offset(AXTextMarkerRangeCopyEndMarker(range))
                guard first <= last, last <= document.length else { return nil }
                return document.substring(with: NSRange(location: first, length: last - first)) as CFString
            default: return nil
            }
        })
    }

    private static func offset(_ marker: AXTextMarker) -> Int {
        Int(AXTextMarkerGetBytePtr(marker).pointee)
    }

    private static func markerRange(_ start: Int, _ end: Int) -> AXTextMarkerRange {
        var first = UInt8(start)
        var last = UInt8(end)
        return AXTextMarkerRangeCreateWithBytes(nil, &first, 1, &last, 1)
    }
}
