import Foundation

struct ResultMarkdownCode: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case comment, string, number, keyword
    }

    struct Token: Equatable, Sendable {
        let range: NSRange
        let kind: Kind
    }

    let text: String
    let language: String?
    let tokens: [Token]

    init(text: String, language: String?) {
        self.text = text
        // Limit the displayed fence label to an identifier.
        let label = language?.prefix(32).prefix(while: { "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+.#-".contains($0) })
        self.language = label.flatMap { $0.isEmpty ? nil : String($0) }
        tokens = Self.highlight(text, language: self.language?.lowercased())
    }

    private static func highlight(_ text: String, language: String?) -> [Token] {
        guard let language, let grammar = grammars[language],
              text.utf8.prefix(12_289).count <= 12_288 else { return [] }
        let source = text as NSString
        var tokens: [Token] = []
        grammar.pattern.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match else { return }
            let kind: Kind
            if match.range(withName: "comment").location != NSNotFound { kind = .comment }
            else if match.range(withName: "string").location != NSNotFound { kind = .string }
            else if match.range(withName: "number").location != NSNotFound { kind = .number }
            else if grammar.keywords.contains(source.substring(with: match.range)) { kind = .keyword }
            else { return }
            tokens.append(Token(range: match.range, kind: kind))
        }
        return tokens
    }

    private struct Grammar {
        let pattern: NSRegularExpression
        let keywords: Set<String>

        init?(comments: String, strings: String, keywords: String) {
            let identifier = #"[\p{L}_$][\p{L}\p{N}_$]*"#
            let number = #"(?:0[xX][[:xdigit:]_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?)"#
            let pattern = "(?<comment>\(comments))|(?<string>\(strings))|(?<number>\(number))|\(identifier)"
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
            self.pattern = expression
            self.keywords = Set(keywords.split(separator: " ").map(String.init))
        }
    }

    private static let grammars: [String: Grammar] = {
        let double = #""(?:\\[^\r\n]|[^"\\\r\n])*""#
        let single = #"'(?:\\[^\r\n]|[^'\\\r\n])*'"#
        let tripleDouble = #"(?s:""".*?(?:"""|\z))"#
        let tripleSingle = #"(?s:'''.*?(?:'''|\z))"#
        let backtick = #"(?s:\x60(?:\\.|[^\x60\\])*\x60)"#
        let quotes = "\(double)|\(single)"
        let slash = #"//[^\r\n]*|(?s:/\*.*?(?:\*/|\z))"#
        let hash = #"#[^\r\n]*"#
        let javascript = "async await break case catch class const continue default do else export extends false finally for function if import in interface let new null of return static super switch this throw true try type typeof undefined var void while"
        let definitions: [([String], Grammar?)] = [
            (["swift"], Grammar(comments: slash, strings: "\(tripleDouble)|\(double)",
                keywords: "actor any as async await break case catch class continue default defer do else enum extension false for func guard if import in init let nil private protocol public return self some static struct switch throw throws true try var where while")),
            (["js", "javascript", "ts", "typescript"], Grammar(comments: slash, strings: "\(backtick)|\(quotes)",
                keywords: javascript)),
            (["json"], Grammar(comments: "(?!)", strings: double, keywords: "true false null")),
            (["py", "python"], Grammar(comments: hash, strings: "\(tripleDouble)|\(tripleSingle)|\(quotes)",
                keywords: "and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield")),
            (["bash", "sh", "shell", "zsh"], Grammar(comments: #"(?<![\w$])#[^\r\n]*"#, strings: quotes,
                keywords: "case do done elif else esac export fi for function if in local readonly return then until while"))
        ]
        var result: [String: Grammar] = [:]
        for (aliases, grammar) in definitions {
            guard let grammar else { continue }
            for alias in aliases { result[alias] = grammar }
        }
        return result
    }()
}
