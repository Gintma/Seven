import AppKit
import XCTest
@testable import Seven

@MainActor
final class EmptyInputSilentTests: XCTestCase {
    func testPlaceholderIsEmptyEvenWhenDocumentAPIRepeatsIt() throws {
        let hint = "⌘ Esc to focus or unfocus Claude"
        for document: String? in [nil, hint] {
            XCTAssertThrowsError(try InputReplacementContent.resolve(value: hint, characterCount: nil,
                placeholder: hint, documentText: document)) { XCTAssertEqual($0 as? InputReplacementError, .empty) }
        }
        let snapshot = try InputReplacementSnapshot(value: hint, range: NSRange(location: 0, length: 0))
        XCTAssertThrowsError(try snapshot.validateContent(placeholder: hint)) { XCTAssertEqual($0 as? InputReplacementError, .empty) }
        XCTAssertEqual(try InputReplacementContent.resolve(value: hint, characterCount: hint.utf16.count,
            placeholder: hint, documentText: nil), hint)
        XCTAssertEqual(try InputReplacementContent.resolve(value: hint, characterCount: nil,
            placeholder: hint, documentText: "real body"), "real body")
    }

    func testTwoNativeEmptyCopiesAreSilentWithoutAXEvidence() async throws {
        for blank: String? in [nil, "", " \n\t"] {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.setString("saved clipboard", forType: .string)
            var copies = 0
            do {
                try await InputReplacementClipboardProbe.verify(pasteboard: board, copy: {
                    copies += 1
                    if let blank { board.clearContents(); board.setString(blank, forType: .string) }
                }, checkTarget: {}, attempts: 2, pause: {})
                XCTFail("应静默结束")
            } catch { XCTAssertEqual(error as? InputReplacementError, .empty) }
            XCTAssertEqual(copies, 2)
            XCTAssertEqual(board.string(forType: .string), "saved clipboard")
        }
    }
    func testTwoEmptyCopiesAreSilentButUnstableCopyAndPermissionsStillFail() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("saved clipboard", forType: .string)
        do {
            try await InputReplacementClipboardProbe.verify(pasteboard: board, copy: {}, checkTarget: {},
                attempts: 1, pause: {})
            XCTFail("两次复制无文字应静默结束")
        } catch { XCTAssertEqual(error as? InputReplacementError, .empty) }
        XCTAssertEqual(board.string(forType: .string), "saved clipboard")
        var copies = 0
        do {
            try await InputReplacementClipboardProbe.verify(pasteboard: board, copy: {
                copies += 1
                board.clearContents()
                board.setString(copies == 1 ? " " : "real body", forType: .string)
            }, checkTarget: {}, attempts: 1, pause: {})
            XCTFail("一空一非空必须作为变化拦截")
        } catch { XCTAssertEqual(error as? InputReplacementError, .contentChanged) }
        do {
            try await InputReplacementClipboardProbe.verify(pasteboard: board, copy: {},
                checkTarget: { throw SelectionReadError.accessibilityPermission },
                attempts: 1, pause: {})
            XCTFail("权限问题不能归为空白")
        } catch { XCTAssertEqual(error as? SelectionReadError, .accessibilityPermission) }
    }

    func testEmptyEditorWithNonemptyAXValuePassesNativeEmptyEvidenceToCopyProbe() async throws {
        let original = try InputReplacementSnapshot(value: "placeholder", range: NSRange(location: 0, length: 0), selectedText: "")
        let selected = try await InputReplacementSelection.selectWholeInput(original: original, read: { original },
            checkTarget: {}, selectAll: {}, attempts: 2, pause: {})
        XCTAssertEqual(selected.range.length, 0)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("saved", forType: .string)
        var copies = 0
        do {
            try await InputReplacementClipboardProbe.verify(pasteboard: board, copy: { copies += 1 },
                checkTarget: { try InputReplacementSelection.validate(original, against: selected) },
                attempts: 2, pause: {})
            XCTFail("应静默结束")
        } catch { XCTAssertEqual(error as? InputReplacementError, .empty) }
        XCTAssertEqual(copies, 2)
        XCTAssertEqual(board.string(forType: .string), "saved")
    }

}
