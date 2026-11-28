import Foundation
import NaturalLanguage

struct LocalLanguageDetection: Equatable, Sendable {
    enum Evidence: Equatable, Sendable {
        case confident
        case preference
        case constrained
        case mixedAmbiguity
        case weakModel
        case noLanguageSignal
    }

    let code: String?
    let evidence: Evidence
}

enum LocalLanguageDetector {
    private struct Candidate {
        let code: String
        let score: Double
    }

    private struct Hypotheses {
        let ranked: [Candidate]

        init(_ scores: [NLLanguage: Double]) {
            var families: [String: Double] = [:]
            for (language, score) in scores {
                families[LocalLanguageDetector.family(of: language.rawValue), default: 0] += score
            }
            ranked = families.map { Candidate(code: $0.key, score: $0.value) }.sorted {
                $0.score == $1.score ? $0.code < $1.code : $0.score > $1.score
            }
        }

        var winner: Candidate? { ranked.first }
        var margin: Double { (winner?.score ?? 0) - (ranked.dropFirst().first?.score ?? 0) }
        var isConfident: Bool { (winner?.score ?? 0) >= 0.80 && margin >= 0.20 }
    }

    private struct Preferences {
        let primary: String
        let secondary: String

        var ordered: [String] { [primary, secondary] }

        var hints: [NLLanguage: Double] {
            Dictionary(uniqueKeysWithValues: LocalLanguageDetector.supportedLanguages.map { language in
                let code = language.rawValue
                let weight: Double
                if code == primary {
                    weight = 1.00
                } else if code == secondary {
                    weight = 0.85
                } else if LocalLanguageDetector.reducedHints.contains(code) {
                    weight = 0.58
                } else {
                    weight = 0.70
                }
                return (language, weight)
            })
        }
    }

    private struct MixedText {
        let nonLatinText: String
        let latinWords: Int
        let nonLatinWords: Int

        init?(_ text: String) {
            let masked = LocalLanguageDetector.removingLatin(from: text)
            guard masked != text, masked.unicodeScalars.contains(where: LocalLanguageDetector.isLetter) else { return nil }

            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = text
            var latinWords = 0
            var nonLatinWords = 0
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let token = String(text[range])
                let nonLatin = LocalLanguageDetector.removingLatin(from: token)
                if nonLatin != token { latinWords += 1 }
                if nonLatin.unicodeScalars.contains(where: LocalLanguageDetector.isLetter) { nonLatinWords += 1 }
                return true
            }
            guard latinWords > 0, nonLatinWords > 0 else { return nil }
            self.nonLatinText = masked
            self.latinWords = latinWords
            self.nonLatinWords = nonLatinWords
        }
    }

    private static let maximumCharacters = 1_000
    private static let hanLanguageFamilies: Set<String> = ["zh-Hans", "ja"]
    private static let supportedLanguages = LanguageCatalog.all.compactMap(\.detection)
    private static let supportedCodes = Set(supportedLanguages.map(\.rawValue))
    private static let reducedHints: Set<String> = ["id", "ms", "tr"]
    private static let latinLetters = try? NSRegularExpression(pattern: #"(?:\p{sc=Latin}\p{M}*)+"#)
    private static let singleLatinWord = try? NSRegularExpression(pattern: #"^(?:\p{sc=Latin}\p{M}*)+(?:[-’'](?:\p{sc=Latin}\p{M}*)+)*$"#)
    private static let han = try? NSRegularExpression(pattern: #"\p{sc=Han}"#)
    private static let onlyHan = try? NSRegularExpression(pattern: #"^\p{sc=Han}+$"#)
    private static let onlyCJK = try? NSRegularExpression(pattern: #"^[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\p{sc=Hangul}]+$"#)
    private static let kana = try? NSRegularExpression(pattern: #"[\p{sc=Hiragana}\p{sc=Katakana}]"#)
    private static let hangul = try? NSRegularExpression(pattern: #"\p{sc=Hangul}"#)

    // These glyphs are valid in both Simplified and Traditional Chinese; single-character transliteration alters some of them, so they cannot be used to vote.
    private static let ambiguousHanForms: Set<Character> = Set("后面台干乾里于余丑只系制征范愿谷云叶松舍斗丰周")

    static func detect(_ text: String, primary: String, secondary: String) -> LocalLanguageDetection {
        let sample = String(text.prefix(maximumCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard sample.unicodeScalars.contains(where: isLetter) else {
            return .init(code: nil, evidence: .noLanguageSignal)
        }

        let preferences = Preferences(primary: primary, secondary: secondary)
        let raw = recognize(sample)
        if raw.winner.map({ isLatinLanguage($0.code) }) != false,
           let mixed = MixedText(sample),
           !(mixed.latinWords >= 2 && raw.isConfident) {
            let isShortHanLabel = mixed.latinWords == 1 && mixed.nonLatinWords == 1
                && matches(onlyHan, letters(in: mixed.nonLatinText)) && !raw.isConfident
            if mixed.nonLatinWords > mixed.latinWords || isShortHanLabel {
                let partRaw = recognize(mixed.nonLatinText)
                let part = classify(mixed.nonLatinText, raw: partRaw, preferences: preferences)
                if let code = part.code, !isLatinLanguage(code) {
                    let evidence: LocalLanguageDetection.Evidence =
                        !isShortHanLabel && part.evidence == .confident ? .confident : .mixedAmbiguity
                    return .init(code: code, evidence: evidence)
                }
            }

            let whole = classify(sample, raw: raw, preferences: preferences)
            if mixed.nonLatinWords >= mixed.latinWords, !raw.isConfident {
                return .init(code: whole.code, evidence: .mixedAmbiguity)
            }
            return whole
        }

        return classify(sample, raw: raw, preferences: preferences)
    }

    static func chineseVariant(of text: String, primary: String, secondary: String) -> String {
        let preferences = Preferences(primary: primary, secondary: secondary)
        let sample = String(text.prefix(maximumCharacters))
        return chineseResult(sample, preferences: preferences, evidence: .confident).code ?? LanguageCatalog.defaultPrimary
    }

    private static func classify(
        _ text: String, raw: Hypotheses, preferences: Preferences
    ) -> LocalLanguageDetection {
        let scriptLetters = letters(in: text)
        if matches(onlyCJK, scriptLetters) {
            let hasKana = matches(kana, scriptLetters)
            let hasHangul = matches(hangul, scriptLetters)
            if hasKana != hasHangul {
                return .init(code: hasKana ? "ja" : "ko", evidence: .confident)
            }
            if !hasKana, matches(onlyHan, scriptLetters), let winner = raw.winner,
               hanLanguageFamilies.contains(winner.code),
               let runnerUp = raw.ranked.dropFirst().first, hanLanguageFamilies.contains(runnerUp.code),
               raw.margin < 0.20,
               let preferred = preferences.ordered.map(family(of:)).first(where: hanLanguageFamilies.contains) {
                let evidence: LocalLanguageDetection.Evidence = preferred == winner.code ? .weakModel : .preference
                return result(for: preferred, in: text, preferences: preferences, evidence: evidence)
            }
        }

        if raw.isConfident, let winner = raw.winner {
            return result(for: winner.code, in: text, preferences: preferences, evidence: .confident)
        }

        let reranked = recognize(text, hints: preferences.hints)
        if matches(singleLatinWord, text), let winner = raw.winner, winner.score < 0.50,
           let preferred = preferences.ordered.first(where: { supportedCodes.contains($0) && isLatinLanguage($0) }) {
            return .init(code: preferred, evidence: .preference)
        }

        let winner = reranked.winner?.code ?? raw.winner?.code
        let evidence: LocalLanguageDetection.Evidence
        if winner == raw.winner?.code {
            evidence = .weakModel
        } else if let rawCode = raw.winner?.code, supportedCodes.contains(rawCode) {
            evidence = .preference
        } else {
            evidence = .constrained
        }
        return result(for: winner, in: text, preferences: preferences, evidence: evidence)
    }

    private static func result(
        for code: String?, in text: String, preferences: Preferences, evidence: LocalLanguageDetection.Evidence
    ) -> LocalLanguageDetection {
        guard let code, supportedCodes.contains(code) else {
            return .init(code: nil, evidence: .weakModel)
        }
        if LanguageCatalog.isChinese(code) { return chineseResult(text, preferences: preferences, evidence: evidence) }
        return .init(code: code, evidence: evidence)
    }

    private static func chineseResult(
        _ text: String, preferences: Preferences, evidence: LocalLanguageDetection.Evidence
    ) -> LocalLanguageDetection {
        let source = text as NSString
        let characters = han?.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            source.substring(with: $0.range)
        } ?? []
        // Separate individual characters with delimiters so round-trip transliteration does not treat phrase or proper-noun context as glyph evidence.
        let distinct = characters.filter { $0.first.map { !ambiguousHanForms.contains($0) } ?? false }
            .joined(separator: " ")
        let hasTraditional = distinct.applyingTransform(StringTransform("Hant-Hans"), reverse: false)
            .map { $0 != distinct } ?? false
        let hasSimplified = distinct.applyingTransform(StringTransform("Hans-Hant"), reverse: false)
            .map { $0 != distinct } ?? false

        if hasTraditional != hasSimplified {
            return .init(code: hasTraditional ? "zh-Hant" : "zh-Hans", evidence: evidence)
        }
        let code = preferences.ordered.first(where: LanguageCatalog.isChinese) ?? LanguageCatalog.defaultPrimary
        return .init(code: code, evidence: hasTraditional ? .mixedAmbiguity : evidence)
    }

    private static func recognize(_ text: String, hints: [NLLanguage: Double]? = nil) -> Hypotheses {
        let recognizer = NLLanguageRecognizer()
        if let hints {
            recognizer.languageConstraints = supportedLanguages
            recognizer.languageHints = hints
        }
        recognizer.processString(text)
        return Hypotheses(recognizer.languageHypotheses(withMaximum: 5))
    }

    private static func family(of code: String) -> String {
        LanguageCatalog.isChinese(code) ? "zh-Hans" : code
    }

    private static func isLatinLanguage(_ code: String) -> Bool {
        Locale.Language(identifier: code).script?.identifier == "Latn"
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    private static func letters(in text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter(isLetter)))
    }

    private static func matches(_ expression: NSRegularExpression?, _ text: String) -> Bool {
        expression?.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    private static func removingLatin(from text: String) -> String {
        latinLetters?.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..<text.endIndex, in: text), withTemplate: " "
        ) ?? text
    }
}
