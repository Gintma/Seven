import AppKit
import XCTest
@testable import Seven

@MainActor
final class ResultMarkdownTests: XCTestCase {
    func testNativeMarkdownPreservesBlocksInlineStylesAndCodeWhitespace() throws {
        let source = """
            # Title

            **bold** *italic* ~~removed~~ `inline` [Link](https://example.com)
            second line

            3. Parent
               - Nested
            4. Another

            > Quoted

            ---

            ```text
            \t  code
              second

            ```

            | Name | Count |
            | :--- | ---: |
            | *Seven* | 2 |
            """
        let document = try ResultMarkdownDocument.parse(source)
        let rendered = ResultMarkdownRenderer(palette: .system).render(document)
        let text = rendered.string as NSString
        func attrs(_ needle: String) throws -> [NSAttributedString.Key: Any] {
            let location = text.range(of: needle).location
            XCTAssertNotEqual(location, NSNotFound, needle)
            guard location != NSNotFound else { throw CocoaError(.coderReadCorrupt) }
            return rendered.attributes(at: location, effectiveRange: nil)
        }
        func paragraph(_ needle: String) throws -> NSParagraphStyle {
            try XCTUnwrap(attrs(needle)[.paragraphStyle] as? NSParagraphStyle)
        }

        XCTAssertEqual(try paragraph("Title").headerLevel, 1)
        let bold = try XCTUnwrap(attrs("bold")[.font] as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        let italic = try XCTUnwrap(attrs("italic")[.font] as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
        XCTAssertEqual(try attrs("removed")[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertTrue(try XCTUnwrap(attrs("inline")[.font] as? NSFont).isFixedPitch)
        XCTAssertEqual(try attrs("Link")[.link] as? URL, URL(string: "https://example.com"))
        XCTAssertTrue(rendered.string.contains("Link\u{2028}second line"))
        XCTAssertTrue(rendered.string.contains("3.\tParent\n•\tNested\n4.\tAnother"))
        XCTAssertGreaterThan(try paragraph("Nested").firstLineHeadIndent, try paragraph("Parent").firstLineHeadIndent)
        XCTAssertFalse(try paragraph("Quoted").textBlocks.isEmpty)
        XCTAssertTrue(rendered.string.contains("────────"))
        XCTAssertTrue(rendered.string.contains("\t  code\n  second\n\n"))
        XCTAssertEqual(try paragraph("code").lineBreakMode, .byCharWrapping)

        let header = try XCTUnwrap(paragraph("Name").textBlocks.last as? NSTextTableBlock)
        let cell = try XCTUnwrap(paragraph("Seven").textBlocks.last as? NSTextTableBlock)
        XCTAssertTrue(header.table === cell.table)
        XCTAssertEqual(cell.startingRow, 1)
        XCTAssertEqual(header.table.numberOfColumns, 2)
        XCTAssertEqual(try paragraph("Count").alignment, .right)

        let view = StreamingResultTextView(frame: NSRect(x: 0, y: 0, width: 260, height: 1))
        view.textContainer?.containerSize = NSSize(width: 260, height: 2000)
        view.replace(with: rendered)
        let layout = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        layout.ensureLayout(for: container)
        let name = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: text.range(of: "Name"), actualCharacterRange: nil), in: container)
        let count = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: text.range(of: "Count"), actualCharacterRange: nil), in: container)
        XCTAssertEqual(name.minY, count.minY, accuracy: 1)
        XCTAssertGreaterThan(count.minX, name.minX)
        XCTAssertLessThanOrEqual(count.maxX, 260)
    }

    func testSpeechKeepsProseAndLabelsWithoutCodeBlocksOrURLs() throws {
        let result = try ResultMarkdownDocument.parse("""
            # Title

            **Say** [named link](https://example.com/sensitive) or <https://example.com/auto>.
            Then read `sample`.

            - First item
              - Second item

            ```
            SECRET CODE
            ```

            Last. https://example.com/bare
            """)
        XCTAssertTrue(result.speechText.contains("Say named link"))
        XCTAssertTrue(result.speechText.contains("Then read sample."))
        XCTAssertTrue(result.speechText.contains("First item\n\nSecond item"))
        XCTAssertTrue(result.speechText.hasSuffix("Last."))
        XCTAssertFalse(result.speechText.contains("SECRET"))
        XCTAssertFalse(result.speechText.contains("https"))
        XCTAssertFalse(result.speechText.contains("**"))
    }

    func testRenderedImagesAndHTMLStayInertAndExternalLinksRequireConsent() throws {
        let document = try ResultMarkdownDocument.parse("""
            ![Alternative](https://example.com/image.png) ![Data image](data:image/png;base64,AA)
            [Local](file:///tmp/sample) [Script](javascript:alert%281%29)
            [Web](https://example.com/link) [HTTP](http://example.com)
            <img src="https://example.com/resource.png">
            """)
        let rendered = ResultMarkdownRenderer(palette: .system).render(document)
        XCTAssertTrue(rendered.string.contains("Alternative Data image"))
        XCTAssertTrue(rendered.string.contains("<img src="))
        XCTAssertFalse(rendered.string.contains("image.png"))
        var links: [URL] = []
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attrs, _, _ in
            XCTAssertNil(attrs[.attachment])
            if let link = attrs[.link] as? URL { links.append(link) }
        }
        XCTAssertEqual(links.map(\.scheme), ["https", "http"])
        var opened: [URL] = []
        var decision: (@MainActor (Bool) -> Void)?
        for invalid in ["file:///tmp/sample", "javascript:alert(1)", "data:text/plain,z", "https://name@example.com"] {
            let url = try XCTUnwrap(URL(string: invalid))
            ResultMarkdownLink.open(url, confirm: { _, _ in XCTFail("危险链接不能弹确认") }, using: { opened.append($0) })
        }
        ResultMarkdownLink.open(links[0], confirm: { url, handler in
            XCTAssertEqual(url, links[0])
            decision = handler
        }, using: { opened.append($0) })
        XCTAssertTrue(opened.isEmpty)
        decision?(false)
        XCTAssertTrue(opened.isEmpty)
        ResultMarkdownLink.open(links[1], confirm: { _, handler in handler(true) }, using: { opened.append($0) })
        XCTAssertEqual(opened, [links[1]])
    }

    func testUnicodeSelectionSurvivesReflowAndCopiesOnlyVisiblePlainText() throws {
        let view = StreamingResultTextView()
        view.isEditable = false
        view.isSelectable = true
        let selection = "👩‍💻 e\u{301}"
        let original = "# Heading\n\n**\(selection)**"
        view.replace(with: NSAttributedString(string: original))
        view.setSelectedRange((original as NSString).range(of: selection))
        let markdown = try ResultMarkdownDocument.parse(original + "\nnext")
        view.replace(with: ResultMarkdownRenderer(palette: .system).render(markdown), preservingSelection: true)
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), selection)

        let clipboard = NSPasteboard(name: .init("SevenTests.Markdown.\(UUID())"))
        defer { clipboard.releaseGlobally() }
        XCTAssertTrue(view.copyPlainSelection(to: clipboard))
        XCTAssertNil(clipboard.data(forType: .rtf))
        XCTAssertNil(clipboard.data(forType: .rtfd))
        XCTAssertNil(clipboard.data(forType: .html))
        XCTAssertEqual(clipboard.string(forType: .string), selection)
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        XCTAssertTrue(view.copyPlainSelection(to: clipboard))
        XCTAssertTrue(clipboard.string(forType: .string)?.contains(selection + "\nnext") == true)
    }

    func testParserBoundsLargeInputAndPathologicalTable() throws {
        let text = String(repeating: "译", count: ResultMarkdownDocument.maximumSourceBytes)
        XCTAssertThrowsError(try ResultMarkdownDocument.parse(text)) {
            XCTAssertEqual($0 as? ResultMarkdownDocument.Fallback, .sourceSize)
        }
        let table = "| A | B | C | D |\n|---|---|---|---|\n" + String(repeating: "| x | y | z | w |\n", count: 100)
        XCTAssertThrowsError(try ResultMarkdownDocument.parse(table)) {
            XCTAssertEqual($0 as? ResultMarkdownDocument.Fallback, .complexity)
        }
    }

    func testUpdatesCoalesceAndReplacePendingWorkOnCompletionAndRetry() async throws {
        var deliveries: [MarkdownSnapshot] = []
        let updates = ResultMarkdownUpdates(interval: .milliseconds(80)) { snapshot, _ in deliveries.append(snapshot) }
        var first = MarkdownOutput()
        updates.submit(MarkdownSnapshot(output: first, text: "First"))
        updates.submit(MarkdownSnapshot(output: first, text: "First **draft**"))
        try await waitUntil { deliveries.count == 1 }
        XCTAssertEqual(deliveries.map(\.text), ["First **draft**"])

        updates.submit(MarkdownSnapshot(output: first, text: "Abandoned"))
        updates.suspend()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(deliveries.count, 1)
        first.status = .interrupted
        updates.submit(MarkdownSnapshot(output: first, text: "Abandoned"))

        var retry = MarkdownOutput()
        updates.submit(MarkdownSnapshot(output: retry, text: "Pending"))
        retry.status = .completed
        updates.submit(MarkdownSnapshot(output: retry, text: "Final **text**"))
        try await waitUntil { deliveries.count == 2 }
        XCTAssertEqual(deliveries.last, MarkdownSnapshot(output: retry, text: "Final **text**"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(deliveries.count, 2)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "等待 Markdown 更新超时")
    }
}
