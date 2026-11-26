import AppKit

@MainActor
struct ResultMarkdownRenderer {
    let palette: ThemePalette

    func render(_ document: ResultMarkdownDocument) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for block in document.blocks {
            let paragraph = style(for: block)
            switch block.content {
            case .paragraph(let runs):
                append(runs, paragraph: paragraph, marker: block.listMarker, to: output)
            case .heading(let level, let runs):
                let scale = 1 + CGFloat(max(1, 5 - level)) * 0.08
                append(runs, paragraph: paragraph, size: Design.Text.content.size * scale, bold: true, to: output)
            case .code(let code):
                paragraph.lineSpacing = 2
                paragraph.lineBreakMode = .byCharWrapping
                let run = ResultMarkdownDocument.Run(text: code, style: .code)
                let value = attributed(run, paragraph: paragraph)
                output.append(value)
                if !code.hasSuffix("\n") { output.append(attributed(.init(text: "\n", style: .code), paragraph: paragraph)) }
            case .rule:
                output.append(attributed(.init(text: "────────\n"), paragraph: paragraph, color: .inkSecondary))
            case .table(let rows, let alignments):
                appendTable(rows, alignments: alignments, paragraph: paragraph, to: output)
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
        if block.quoteDepth > 0 {
            let bar = NSTextBlock()
            bar.setWidth(2, type: .absoluteValueType, for: .border, edge: .minX)
            bar.setWidth(Design.Space.s, type: .absoluteValueType, for: .padding, edge: .minX)
            bar.setBorderColor(palette.separator, for: .minX)
            style.textBlocks = [bar]
        }
        return style
    }

    private func append(
        _ runs: [ResultMarkdownDocument.Run], paragraph: NSParagraphStyle,
        marker: String? = nil, size: CGFloat = Design.Text.content.size, bold: Bool = false,
        to output: NSMutableAttributedString
    ) {
        if let marker { output.append(attributed(.init(text: marker + "\t"), paragraph: paragraph, size: size)) }
        for var run in runs {
            if run.text == "\n" {
                run = .init(text: "\u{2028}", style: run.style, link: run.link, speaks: run.speaks)
            }
            output.append(attributed(run, paragraph: paragraph, size: size, bold: bold))
        }
        output.append(attributed(.init(text: "\n"), paragraph: paragraph, size: size))
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

    private func appendTable(
        _ rows: [[[ResultMarkdownDocument.Run]]], alignments: [ResultMarkdownDocument.Alignment],
        paragraph: NSMutableParagraphStyle, to output: NSMutableAttributedString
    ) {
        let table = NSTextTable()
        table.numberOfColumns = alignments.count
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        for (rowIndex, row) in rows.enumerated() {
            for (column, alignment) in alignments.enumerated() {
                let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                           startingColumn: column, columnSpan: 1)
                cell.setValue(100 / CGFloat(alignments.count), type: .percentageValueType, for: .width)
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
        output.append(attributed(.init(text: "\n"), paragraph: paragraph))
    }
}
