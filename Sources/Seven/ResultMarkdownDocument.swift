import Foundation
import Markdown

struct ResultMarkdownDocument: Equatable, Sendable {
    struct Style: OptionSet, Equatable, Sendable {
        let rawValue: Int
        static let bold = Self(rawValue: 1)
        static let italic = Self(rawValue: 2)
        static let strike = Self(rawValue: 4)
        static let code = Self(rawValue: 8)
    }

    struct Run: Equatable, Sendable {
        let text: String
        var style: Style = []
        var link: URL?
        var speaks = true
    }

    enum Alignment: Equatable, Sendable {
        case left, center, right
    }

    struct Block: Equatable, Sendable {
        enum Content: Equatable, Sendable {
            case paragraph([Run])
            case heading(Int, [Run])
            case code(ResultMarkdownCode)
            case rule
            case table([[[Run]]], [Alignment])
        }

        let content: Content
        var indent = 0
        var quoteDepth = 0
        var listMarker: String?
    }

    let blocks: [Block]
    let speechText: String

    var hasWidthDependentLayout: Bool {
        blocks.contains { block in
            if case .table = block.content { return true }
            return false
        }
    }

    enum Fallback: String, Error, Equatable, Sendable {
        case sourceSize, complexity
    }

    static let maximumSourceBytes = 48 * 1024

    static func parse(_ source: String) throws -> Self {
        guard source.utf8.prefix(maximumSourceBytes + 1).count <= maximumSourceBytes else { throw Fallback.sourceSize }
        let document = Document(parsing: source)
        let sourceLines = source.contains("**") ? source.split(omittingEmptySubsequences: false) {
            $0 == "\n" || $0 == "\r" || $0 == "\r\n"
        } : []
        var parser = Parser(sourceLines: sourceLines)
        let blocks = try parser.blocks(document.children)
        return Self(blocks: blocks, speechText: spokenText(blocks))
    }

    static func safeLink(_ destination: String) -> URL? {
        guard let parts = URLComponents(string: destination),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }

    private static let spokenURL = #/https?:\/\/[^\s<>]+/#.ignoresCase()

    private static func spokenText(_ blocks: [Block]) -> String {
        func spokenRuns(_ runs: [Run]) -> String {
            runs.filter(\.speaks).map(\.text).joined()
                .replacing(spokenURL, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return blocks.compactMap { block -> String? in
            switch block.content {
            case .paragraph(let runs), .heading(_, let runs):
                let value = spokenRuns(runs)
                return value.isEmpty ? nil : value
            case .table(let rows, _):
                return rows.map { $0.map(spokenRuns).filter { !$0.isEmpty }.joined(separator: ". ") }
                    .filter { !$0.isEmpty }.joined(separator: "\n")
            case .code, .rule:
                return nil
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private struct Parser {
        private static let boldLabel = #/^\*\*([\p{L}\p{M}\p{N}][\p{L}\p{M}\p{N}\p{Zs}]{0,23}[:：])([\p{Zs}\t]*)\*\*/#
        let sourceLines: [Substring]
        var remainingNodes = 3500
        var remainingCells = 360

        mutating func checkBudget(_ depth: Int) throws {
            remainingNodes -= 1
            guard depth < 24, remainingNodes >= 0 else { throw Fallback.complexity }
        }

        mutating func blocks(_ nodes: MarkupChildren, indent: Int = 0, quote: Int = 0, depth: Int = 0) throws -> [Block] {
            var blocks: [Block] = []
            for node in nodes {
                try checkBudget(depth)
                let content: Block.Content
                switch node {
                case let item as Paragraph:
                    content = .paragraph(try runs(item.children, depth: depth + 1, repairsLeadingLabels: true))
                case let item as Heading: content = .heading(item.level, try runs(item.children, depth: depth + 1))
                case let item as CodeBlock: content = .code(ResultMarkdownCode(text: item.code, language: item.language))
                case let item as HTMLBlock: content = .paragraph([Run(text: item.rawHTML, speaks: false)])
                case is ThematicBreak: content = .rule
                case let item as Table: content = try table(item, depth: depth + 1)
                case is BlockQuote:
                    blocks += try self.blocks(node.children, indent: indent, quote: quote + 1, depth: depth + 1)
                    continue
                case is OrderedList, is UnorderedList:
                    let start = (node as? OrderedList)?.startIndex
                    for (offset, item) in node.children.enumerated() {
                        try checkBudget(depth + 1)
                        var children = try self.blocks(item.children, indent: indent + 1, quote: quote, depth: depth + 2)
                        let marker = switch (item as? ListItem)?.checkbox {
                        case .checked: "☑"
                        case .unchecked: "☐"
                        case nil: start.map { "\($0 + UInt(offset))." } ?? "•"
                        }
                        if let first = children.first, first.indent == indent + 1,
                           case .paragraph = first.content, first.quoteDepth == quote {
                            children[0].listMarker = marker
                        } else {
                            children.insert(Block(content: .paragraph([]), indent: indent + 1,
                                                  quoteDepth: quote, listMarker: marker), at: 0)
                        }
                        blocks += children
                    }
                    continue
                default:
                    blocks += try self.blocks(node.children, indent: indent, quote: quote, depth: depth + 1)
                    continue
                }
                blocks.append(Block(content: content, indent: indent, quoteDepth: quote))
            }
            return blocks
        }

        mutating func table(_ table: Table, depth: Int) throws -> Block.Content {
            let alignments = table.columnAlignments.map { alignment -> Alignment in
                switch alignment {
                case .center: return .center
                case .right: return .right
                default: return .left
                }
            }
            let columns = alignments.count
            guard columns > 0, columns <= 24,
                  table.body.childCount < remainingCells / columns else { throw Fallback.complexity }
            remainingCells -= (table.body.childCount + 1) * columns
            var rows = [try table.head.cells.map { try runs($0.children, depth: depth) }]
            rows += try table.body.rows.map { row in try row.cells.map { try runs($0.children, depth: depth) } }
            return .table(rows, alignments)
        }

        mutating func runs(
            _ nodes: MarkupChildren, style: Style = [], depth: Int, repairsLeadingLabels: Bool = false
        ) throws -> [Run] {
            var runs: [Run] = []
            var isAtLineStart = repairsLeadingLabels
            for node in nodes {
                try checkBudget(depth)
                let repairLabel = isAtLineStart
                isAtLineStart = repairsLeadingLabels && (node is SoftBreak || node is LineBreak)
                switch node {
                case let value as Markdown.Text:
                    if repairLabel, let label = repairedBoldLabel(value, style: style) {
                        runs += label
                    } else {
                        runs.append(Run(text: value.string, style: style))
                    }
                case let value as InlineCode:
                    runs.append(Run(text: value.code, style: style.union(.code)))
                case let value as InlineHTML:
                    runs.append(Run(text: value.rawHTML, style: style, speaks: false))
                case is SoftBreak, is LineBreak:
                    runs.append(Run(text: "\n", style: style))
                case let value as Link:
                    var label = try self.runs(node.children, style: style, depth: depth + 1)
                    if let destination = value.destination {
                        let link = ResultMarkdownDocument.safeLink(destination)
                        let labelIsURL = label.map(\.text).joined() == destination
                        for index in label.indices {
                            label[index].link = link
                            if labelIsURL { label[index].speaks = false }
                        }
                    }
                    runs += label
                default:
                    var childStyle = style
                    if node is Strong { childStyle.insert(.bold) }
                    if node is Emphasis { childStyle.insert(.italic) }
                    if node is Strikethrough { childStyle.insert(.strike) }
                    // Keep only alt text for images; parsed results do not retain image URLs.
                    runs += try self.runs(node.children, style: childStyle, depth: depth + 1)
                }
            }
            return runs
        }

        /// Model responses sometimes leave a space inside the closing stars or omit the
        /// separator after a bold label. Only repair literal prose with unescaped source markers.
        private func repairedBoldLabel(_ value: Markdown.Text, style: Style) -> [Run]? {
            let text = value.string
            guard text.hasPrefix("**"), let match = text.prefixMatch(of: Self.boldLabel),
                  let start = value.range?.lowerBound,
                  sourceLines.indices.contains(start.line - 1), start.column > 0,
                  sourceLines[start.line - 1].utf8.dropFirst(start.column - 1)
                    .starts(with: text[match.range].utf8) else { return nil }
            let remainder = text[match.range.upperBound...]
            guard remainder.first != "*" else { return nil }
            return [
                Run(text: String(match.output.1), style: style.union(.bold)),
                Run(text: String(match.output.2) + remainder, style: style)
            ]
        }
    }
}
