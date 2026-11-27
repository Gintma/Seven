import AppKit

@MainActor
struct ResultMarkdownRenderer {
    let palette: ThemePalette

    static let codeBlockAttribute = NSAttributedString.Key("SevenMarkdownCodeBlock")
    static let quoteDepthAttribute = NSAttributedString.Key("SevenMarkdownQuoteDepth")
    static let ruleAttribute = NSAttributedString.Key("SevenMarkdownRule")

    func render(_ document: ResultMarkdownDocument, availableWidth: CGFloat? = nil) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, block) in document.blocks.enumerated() {
            let hasNextBlock = index + 1 < document.blocks.count
            let blockStart = output.length
            let paragraph = style(for: block)
            switch block.content {
            case .paragraph(let runs):
                append(runs, paragraph: paragraph, marker: block.listMarker, terminatesParagraph: hasNextBlock, to: output)
            case .heading(let level, let runs):
                let scale = 1 + CGFloat(max(1, 5 - level)) * 0.08
                append(runs, paragraph: paragraph, size: Design.Text.content.size * scale, bold: true,
                       terminatesParagraph: hasNextBlock, to: output)
            case .code(let code):
                paragraph.lineSpacing = 2
                paragraph.lineBreakMode = .byCharWrapping
                paragraph.headIndent += Design.Space.s
                paragraph.firstLineHeadIndent = paragraph.headIndent
                paragraph.tailIndent = -Design.Space.s
                let codeText = hasNextBlock && !code.hasSuffix("\n") ? code + "\n" : code
                let codeRange = NSRange(location: output.length, length: (codeText as NSString).length)
                output.append(attributed(.init(text: codeText, style: .code), paragraph: paragraph))
                output.removeAttribute(.backgroundColor, range: codeRange)
                output.addAttribute(Self.codeBlockAttribute, value: index, range: codeRange)
            case .rule:
                let rule = NSMutableAttributedString(attributedString: attributed(.init(text: "\u{200B}"), paragraph: paragraph))
                rule.addAttribute(Self.ruleAttribute, value: true, range: NSRange(location: 0, length: rule.length))
                output.append(rule)
                if hasNextBlock { output.append(attributed(.init(text: "\n"), paragraph: paragraph)) }
            case .table(let rows, let alignments):
                let viewportWidth = availableWidth.map { $0 - paragraph.firstLineHeadIndent }
                if let viewportWidth, let widths = overflowingColumnWidths(rows, count: alignments.count, viewportWidth: viewportWidth) {
                    let contents = NSMutableAttributedString()
                    appendTable(rows, alignments: alignments, paragraph: NSMutableParagraphStyle(),
                                separatesFollowingBlock: false, widths: widths, to: contents)
                    let plain = rows.map { row in row.map { $0.map(\.text).joined() }.joined(separator: "\t") }.joined(separator: "\n")
                    let width = widths.reduce(0, +) + 4
                    let table = ResultMarkdownWideTable(blockIndex: index, content: contents, plainText: plain, width: width)
                    let attachment = table.attachment(viewportWidth: viewportWidth)
                    attachment.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attachment.length))
                    output.append(attachment)
                    if hasNextBlock { output.append(attributed(.init(text: "\n"), paragraph: paragraph)) }
                } else {
                    appendTable(rows, alignments: alignments, paragraph: paragraph, separatesFollowingBlock: hasNextBlock, to: output)
                }
            }
            if block.quoteDepth > 0, output.length > blockStart {
                output.addAttribute(Self.quoteDepthAttribute, value: block.quoteDepth,
                                    range: NSRange(location: blockStart, length: output.length - blockStart))
            }
        }
        return output
    }

    private func style(for block: ResultMarkdownDocument.Block) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = block.indent > 0 ? 3 : 7
        let quoteIndent = CGFloat(block.quoteDepth) * Design.Space.m
        let listIndent = CGFloat(block.indent) * Design.Text.content.size
        style.headIndent = quoteIndent + listIndent
        style.firstLineHeadIndent = style.headIndent
        if let marker = block.listMarker {
            let markerWidth = (marker as NSString).size(withAttributes: [.font: Design.Text.content.nsFont]).width
            style.headIndent += max(Design.Text.content.size, markerWidth + Design.Space.s)
            style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
        }
        style.headerLevel = {
            if case .heading(let level, _) = block.content { return level }
            return 0
        }()
        return style
    }

    private func append(
        _ runs: [ResultMarkdownDocument.Run], paragraph: NSParagraphStyle,
        marker: String? = nil, size: CGFloat = Design.Text.content.size, bold: Bool = false,
        terminatesParagraph: Bool = true, to output: NSMutableAttributedString
    ) {
        if let marker { output.append(attributed(.init(text: marker + "\t"), paragraph: paragraph, size: size)) }
        for var run in runs {
            if run.text == "\n" {
                run = .init(text: "\u{2028}", style: run.style, link: run.link, speaks: run.speaks)
            }
            output.append(attributed(run, paragraph: paragraph, size: size, bold: bold))
        }
        if terminatesParagraph { output.append(attributed(.init(text: "\n"), paragraph: paragraph, size: size)) }
    }

    private func attributed(
        _ run: ResultMarkdownDocument.Run, paragraph: NSParagraphStyle,
        size: CGFloat = Design.Text.content.size, bold: Bool = false, color: ThemeToken = .ink
    ) -> NSAttributedString {
        let weight: NSFont.Weight = bold || run.style.contains(.bold) ? .semibold : .regular
        var font = run.style.contains(.code)
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        if run.style.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        let foreground: ThemeToken = run.link == nil ? color : .link
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: palette[foreground], .paragraphStyle: paragraph,
            StreamingResultTextView.themeTokenAttribute: foreground.rawValue
        ]
        if run.style.contains(.code) { attributes[.backgroundColor] = palette.surfaceInset }
        if run.style.contains(.strike) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = run.link { attributes[.link] = link }
        return NSAttributedString(string: run.text, attributes: attributes)
    }

    private func overflowingColumnWidths(
        _ rows: [[[ResultMarkdownDocument.Run]]], count: Int, viewportWidth: CGFloat
    ) -> [CGFloat]? {
        guard viewportWidth >= 80, count > 0 else { return nil }
        var widths = Array(repeating: CGFloat(64), count: count)
        for (rowIndex, row) in rows.enumerated() {
            let font = NSFont.systemFont(ofSize: Design.Text.content.size, weight: rowIndex == 0 ? .semibold : .regular)
            for (column, runs) in row.prefix(count).enumerated() {
                let text = runs.map(\.text).joined()
                // Measure a bounded sample. Very long cells wrap inside their column.
                let sample = String(text.prefix(48))
                let width = min(320, ceil((sample as NSString).size(withAttributes: [.font: font]).width) + 20)
                widths[column] = max(widths[column], width)
            }
        }
        let equalColumnWidth = viewportWidth / CGFloat(count)
        // Leave small tables in the main text view when the cells can wrap comfortably.
        guard widths.reduce(0, +) > viewportWidth,
              count >= 4 || widths.contains(where: { $0 > equalColumnWidth * 1.6 }) else { return nil }
        return widths
    }

    private func appendTable(
        _ rows: [[[ResultMarkdownDocument.Run]]], alignments: [ResultMarkdownDocument.Alignment],
        paragraph: NSMutableParagraphStyle, separatesFollowingBlock: Bool, widths: [CGFloat]? = nil,
        to output: NSMutableAttributedString
    ) {
        let table = NSTextTable()
        table.numberOfColumns = alignments.count
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        // TextKit positions collapsed borders on half points outside the table width.
        let totalWidth = widths?.reduce(0, +)
        table.setValue(totalWidth ?? 99, type: totalWidth == nil ? .percentageValueType : .absoluteValueType, for: .width)
        for (rowIndex, row) in rows.enumerated() {
            for (column, alignment) in alignments.enumerated() {
                let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                           startingColumn: column, columnSpan: 1)
                let percentage = if let widths, let totalWidth { widths[column] / totalWidth * 100 }
                    else { 100 / CGFloat(alignments.count) }
                cell.setValue(percentage, type: .percentageValueType, for: .width)
                cell.setWidth(1, type: .absoluteValueType, for: .border)
                cell.setWidth(Design.Space.s, type: .absoluteValueType, for: .padding)
                cell.setBorderColor(palette.separator)
                if rowIndex == 0 { cell.backgroundColor = palette.surfaceInset }
                let style = (paragraph.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                style.textBlocks.append(cell)
                style.paragraphSpacing = 0
                style.alignment = switch alignment {
                case .left: .left
                case .center: .center
                case .right: .right
                }
                let runs = column < row.count ? row[column] : []
                append(runs, paragraph: style, bold: rowIndex == 0, to: output)
            }
        }
        if separatesFollowingBlock { output.append(attributed(.init(text: "\n"), paragraph: paragraph)) }
    }
}
