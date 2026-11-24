import CommonCrypto
import CryptoKit
import Foundation

struct OnlineTranslationRequest: Equatable, Sendable {
    let text: String
    let source: String
    let target: String
}

struct OnlineTranslationOutput: Equatable, Sendable {
    let text: String
    let dictionaryEntry: DictionaryEntry?
}

protocol OnlineTranslationServing: Sendable {
    func translate(_ request: OnlineTranslationRequest) async throws -> OnlineTranslationOutput
}

enum FormEncoding {
    static func data(_ parameters: [(String, String)]) throws -> Data {
        var components = URLComponents()
        components.queryItems = parameters.map(URLQueryItem.init(name:value:))
        guard let query = components.percentEncodedQuery else {
            throw TranslationError.malformed
        }
        return Data(query.utf8)
    }

    static func url(_ endpoint: URL, parameters: [(String, String)]) throws -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = parameters.map(URLQueryItem.init(name:value:))
        guard let url = components?.url else { throw TranslationError.malformed }
        return url
    }
}

func onlineTranslationSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 45
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    return URLSession(
        configuration: configuration,
        delegate: NoRedirectDelegate(),
        delegateQueue: nil
    )
}

private func validateHTTPResponse(_ response: URLResponse) throws {
    guard let response = response as? HTTPURLResponse else {
        throw TranslationError.malformed
    }
    guard (200..<300).contains(response.statusCode) else {
        throw TranslationError.http(response.statusCode)
    }
}

private func mapNetworkError(_ error: Error, serviceName: LocalizedMessage.Argument) -> Error {
    guard let error = error as? URLError else { return error }
    if error.code == .cancelled { return CancellationError() }
    if error.code == .timedOut {
        return TranslationError.transport(.key("service.requestTimedOut", serviceName))
    }
    return TranslationError.transport(.key("service.unreachable", serviceName))
}

final class GoogleTranslationService: OnlineTranslationServing, @unchecked Sendable {
    static let endpoint = URL(string: "https://translate.google.com/translate_a/single")!

    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? onlineTranslationSession()
    }

    deinit { session.invalidateAndCancel() }

    func translate(_ input: OnlineTranslationRequest) async throws -> OnlineTranslationOutput {
        do {
            let request = try Self.makeRequest(input)
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            return OnlineTranslationOutput(
                text: try Self.parse(data, response: response),
                dictionaryEntry: nil
            )
        } catch {
            throw mapNetworkError(error, serviceName: .key("googleTranslate"))
        }
    }

    static func makeRequest(_ input: OnlineTranslationRequest) throws -> URLRequest {
        guard let source = languageCode(for: input.source, allowsAutomatic: true),
              let target = languageCode(for: input.target, allowsAutomatic: false) else {
            throw TranslationError.configuration(.key("googleTranslateDoesNotSupportThisLanguage"))
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = try FormEncoding.data([
            ("q", input.text),
            ("sl", source),
            ("tl", target),
            ("dt", "t"),
            ("dj", "1"),
            ("ie", "UTF-8"),
            ("client", "gtx")
        ])
        return request
    }

    static func parse(_ data: Data, response: URLResponse) throws -> String {
        try validateHTTPResponse(response)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sentences = object["sentences"] as? [[String: Any]] else {
            throw TranslationError.malformed
        }
        let translated = sentences.compactMap { $0["trans"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { throw TranslationError.empty }
        return translated
    }

    private static func languageCode(for language: String, allowsAutomatic: Bool) -> String? {
        if language == LanguageCatalog.automatic { return allowsAutomatic ? "auto" : nil }
        return LanguageCatalog.language(language)?.googleCode
    }
}

final class YoudaoTranslationService: OnlineTranslationServing, @unchecked Sendable {
    struct KeyMaterial: Codable, Equatable, Sendable {
        let secretKey: String
        let aesKey: String
        let aesIv: String
    }

    private struct KeyEnvelope: Codable {
        let data: KeyMaterial
        let code: Int
    }

    private struct TranslationEnvelope: Codable {
        struct Item: Codable {
            let tgt: String
        }

        let translateResult: [[Item]]?
        let code: Int
    }

    private struct DictionaryEnvelope: Decodable {
        struct EC: Decodable {
            struct Word: Decodable {
                struct Translation: Decodable {
                    let pos: String?
                    let tran: String?
                }

                struct WordFormContainer: Decodable {
                    struct WordForm: Decodable {
                        let name: String?
                        let value: String?
                    }

                    let wf: WordForm?
                }

                let usphone: String?
                let ukphone: String?
                let trs: [Translation]?
                let wfs: [WordFormContainer]?
                let returnPhrase: String?

                private enum CodingKeys: String, CodingKey {
                    case usphone, ukphone, trs, wfs
                    case returnPhrase = "return-phrase"
                }
            }

            let examType: [String]?
            let word: Word?

            private enum CodingKeys: String, CodingKey {
                case examType = "exam_type"
                case word
            }
        }

        struct WebTrans: Decodable {
            struct Entry: Decodable {
                struct Meaning: Decodable {
                    let value: String?
                }

                let key: String?
                let trans: [Meaning]?
            }

            let entries: [Entry]?

            private enum CodingKeys: String, CodingKey {
                case entries = "web-translation"
            }
        }

        struct EnglishDictionary: Decodable {
            struct Word: Decodable {
                struct Part: Decodable {
                    struct Definition: Decodable {
                        let tran: String?
                    }

                    let pos: String?
                    let tr: [Definition]?
                }

                let trs: [Part]?
            }

            let word: Word?
        }

        struct BilingualSentences: Decodable {
            struct Pair: Decodable {
                let sentence: String?
                let translation: String?

                private enum CodingKeys: String, CodingKey {
                    case sentence
                    case translation = "sentence-translation"
                }
            }

            let pairs: [Pair]?

            private enum CodingKeys: String, CodingKey {
                case pairs = "sentence-pair"
            }
        }

        let ec: EC?
        let webTrans: WebTrans?
        let englishDictionary: EnglishDictionary?
        let bilingualSentences: BilingualSentences?

        private enum CodingKeys: String, CodingKey {
            case ec
            case webTrans = "web_trans"
            case englishDictionary = "ee"
            case bilingualSentences = "blng_sents_part"
        }
    }

    static let keyEndpoint = URL(string: "https://dict.youdao.com/webtranslate/key")!
    static let translationEndpoint = URL(string: "https://dict.youdao.com/webtranslate")!
    static let dictionaryEndpoint = URL(string: "https://dict.youdao.com/jsonapi_s?doctype=json&jsonversion=4")!

    private static let client = "fanyideskweb"
    private static let product = "webfanyi"
    private static let defaultKey = "asdjnjfenknafdfsdfsd"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/131.0 Safari/537.36"

    private let session: URLSession
    private let cookie: String

    init(session: URLSession? = nil) {
        self.session = session ?? onlineTranslationSession()
        self.cookie = "OUTFOX_SEARCH_USER_ID=\(Int.random(in: 100_000_000...999_999_999))@10.0.0.1;"
    }

    deinit { session.invalidateAndCancel() }

    func translate(_ input: OnlineTranslationRequest) async throws -> OnlineTranslationOutput {
        async let dictionaryEntry = dictionaryEntry(for: input.text)
        let text = try await translateText(input)
        return OnlineTranslationOutput(
            text: text,
            dictionaryEntry: try? await dictionaryEntry
        )
    }

    private func translateText(_ input: OnlineTranslationRequest) async throws -> String {
        do {
            let keyTimestamp = Self.timestamp()
            let keyRequest = try Self.makeKeyRequest(timestamp: keyTimestamp, cookie: cookie)
            let (keyData, keyResponse) = try await session.data(for: keyRequest)
            try Task.checkCancellation()
            let key = try Self.parseKey(keyData, response: keyResponse)

            let translationTimestamp = Self.timestamp()
            let request = try Self.makeTranslationRequest(
                input,
                key: key,
                timestamp: translationTimestamp,
                cookie: cookie
            )
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            try validateHTTPResponse(response)
            let decrypted = try Self.decrypt(data, aesKey: key.aesKey, aesIV: key.aesIv)
            return try Self.parseTranslation(decrypted)
        } catch {
            throw mapNetworkError(error, serviceName: .key("youdaoTranslate"))
        }
    }

    private func dictionaryEntry(for text: String) async throws -> DictionaryEntry? {
        guard ECDictionaryService.normalizedQuery(text) != nil else { return nil }
        let request = try Self.makeDictionaryRequest(text: text, cookie: cookie)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        return try Self.parseDictionary(data, response: response, fallbackHeadword: text)
    }

    static func makeKeyRequest(timestamp: String, cookie: String) throws -> URLRequest {
        let sign = signature(timestamp: timestamp, key: defaultKey)
        let url = try FormEncoding.url(keyEndpoint, parameters: generalParameters + [
            ("keyid", "webfanyi-key-getter"),
            ("sign", sign),
            ("mysticTime", timestamp)
        ])
        return request(url: url, method: "GET", cookie: cookie)
    }

    static func makeTranslationRequest(
        _ input: OnlineTranslationRequest,
        key: KeyMaterial,
        timestamp: String,
        cookie: String
    ) throws -> URLRequest {
        guard let source = languageCode(for: input.source, allowsAutomatic: true),
              let target = languageCode(for: input.target, allowsAutomatic: false) else {
            throw TranslationError.configuration(.key("youdaoTranslateDoesNotSupportThisLanguage"))
        }
        let sign = signature(timestamp: timestamp, key: key.secretKey)
        var request = request(url: translationEndpoint, method: "POST", cookie: cookie)
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = try FormEncoding.data(generalParameters + [
            ("i", input.text),
            ("from", source),
            ("to", target),
            ("dictResult", "false"),
            ("keyid", "webfanyi"),
            ("sign", sign),
            ("mysticTime", timestamp)
        ])
        return request
    }

    static func makeDictionaryRequest(text: String, cookie: String) throws -> URLRequest {
        let seed = text + "webdict"
        let time = String(seed.count % 10)
        let salt = md5Hex(seed)
        let sign = md5Hex("web\(text)\(time)Mk6hqtUp33DGGtoS63tTJbMUYjRrG1Lu\(salt)")
        var request = request(url: dictionaryEndpoint, method: "POST", cookie: cookie)
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = try FormEncoding.data([
            ("q", text),
            ("le", "en"),
            ("client", "web"),
            ("t", time),
            ("sign", sign),
            ("keyfrom", "webdict")
        ])
        return request
    }

    static func signature(timestamp: String, key: String) -> String {
        md5Hex("client=\(client)&mysticTime=\(timestamp)&product=\(product)&key=\(key)")
    }

    static func parseKey(_ data: Data, response: URLResponse) throws -> KeyMaterial {
        try validateHTTPResponse(response)
        guard let envelope = try? JSONDecoder().decode(KeyEnvelope.self, from: data),
              envelope.code == 0,
              !envelope.data.secretKey.isEmpty,
              !envelope.data.aesKey.isEmpty,
              !envelope.data.aesIv.isEmpty else {
            throw TranslationError.malformed
        }
        return envelope.data
    }

    static func decrypt(_ data: Data, aesKey: String, aesIV: String) throws -> Data {
        guard var encoded = String(data: data, encoding: .utf8) else {
            throw TranslationError.malformed
        }
        encoded = encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let encrypted = Data(base64Encoded: encoded) else {
            throw TranslationError.malformed
        }

        let key = Data(Insecure.MD5.hash(data: Data(aesKey.utf8)))
        let iv = Data(Insecure.MD5.hash(data: Data(aesIV.utf8)))
        let outputCapacity = encrypted.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var written = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            encrypted.withUnsafeBytes { encryptedBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            encryptedBytes.baseAddress,
                            encrypted.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw TranslationError.malformed }
        output.removeSubrange(written..<output.count)
        return output
    }

    static func parseTranslation(_ data: Data) throws -> String {
        guard let envelope = try? JSONDecoder().decode(TranslationEnvelope.self, from: data) else {
            throw TranslationError.malformed
        }
        // 错误码 40：语言不受支持（2026-10-30 联网核对，如英语→斯瓦希里语、斯瓦希里语→中文）。
        if envelope.code == 40 { throw TranslationError.unsupportedLanguage(.key("youdaoTranslateDoesNotSupportTheLanguage")) }
        guard envelope.code == 0 else {
            throw TranslationError.transport(.key("youdao.unavailable", .text(String(describing: envelope.code))))
        }
        let paragraphs = (envelope.translateResult ?? []).map { $0.map(\.tgt).joined() }
        var combined = ""
        for (index, paragraph) in paragraphs.enumerated() {
            // 有道段落可能自带换行；仅在边界两侧都没有换行时补分隔，保留原有空行。
            if index > 0, paragraphs[index - 1].last?.isNewline != true,
               paragraph.first?.isNewline != true {
                combined.append("\n")
            }
            combined.append(paragraph)
        }
        let translated = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { throw TranslationError.empty }
        return translated
    }

    static func parseDictionary(
        _ data: Data,
        response: URLResponse,
        fallbackHeadword: String
    ) throws -> DictionaryEntry? {
        try validateHTTPResponse(response)
        guard let envelope = try? JSONDecoder().decode(DictionaryEnvelope.self, from: data),
              let ec = envelope.ec,
              let word = ec.word else { return nil }

        var pronunciations: [DictionaryPronunciation] = []
        if let value = word.usphone?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            pronunciations.append(.init(label: "美", value: value))
        }
        if let value = word.ukphone?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            pronunciations.append(.init(label: "英", value: value))
        }

        let blocks = (word.trs ?? []).enumerated().compactMap { index, item -> DictionaryBlock? in
            let meaning = item.tran?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !meaning.isEmpty else { return nil }
            let part = item.pos?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return DictionaryBlock(
                id: index,
                text: part.isEmpty ? meaning : "\(part)  \(meaning)"
            )
        }
        let forms = (word.wfs ?? []).enumerated().compactMap { index, container -> DictionaryForm? in
            guard let name = container.wf?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let value = container.wf?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, !value.isEmpty else { return nil }
            return DictionaryForm(id: index, label: name, value: value)
        }
        let phrases = (envelope.webTrans?.entries ?? []).prefix(5).enumerated().compactMap {
            index, entry -> DictionaryPhrase? in
            guard let title = entry.key?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                return nil
            }
            let meanings = (entry.trans ?? []).compactMap { meaning in
                meaning.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            guard !meanings.isEmpty else { return nil }
            return DictionaryPhrase(id: index, title: title, meanings: meanings)
        }
        let englishDefinitions = (envelope.englishDictionary?.word?.trs ?? []).flatMap { part in
            (part.tr ?? []).compactMap { definition -> String? in
                guard let meaning = definition.tran?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !meaning.isEmpty else { return nil }
                let prefix = part.pos?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return prefix.isEmpty ? meaning : "\(prefix)  \(meaning)"
            }
        }
        let examples = (envelope.bilingualSentences?.pairs ?? []).prefix(3).enumerated().compactMap {
            index, pair -> DictionaryExample? in
            guard let source = pair.sentence?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let translation = pair.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !source.isEmpty, !translation.isEmpty else { return nil }
            return DictionaryExample(id: index, source: source, translation: translation)
        }
        guard !blocks.isEmpty || !pronunciations.isEmpty || !forms.isEmpty || !phrases.isEmpty else { return nil }
        let returnedHeadword = word.returnPhrase?.trimmingCharacters(in: .whitespacesAndNewlines)
        let headword = returnedHeadword?.isEmpty == false ? returnedHeadword! : fallbackHeadword
        return DictionaryEntry(
            headword: headword,
            pronunciations: pronunciations,
            blocks: blocks,
            englishDefinitions: englishDefinitions,
            forms: forms,
            labels: ec.examType ?? [],
            phrases: phrases,
            examples: examples,
            rawText: String(data: data, encoding: .utf8) ?? ""
        )
    }

    private static var generalParameters: [(String, String)] {
        [
            ("client", client),
            ("product", product),
            ("appVersion", "1.0.0"),
            ("vendor", "web"),
            ("pointParam", "client,mysticTime,product"),
            ("keyfrom", "fanyi.web")
        ]
    }

    private static func request(url: URL, method: String, cookie: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://fanyi.youdao.com/", forHTTPHeaderField: "Referer")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        return request
    }

    private static func timestamp() -> String {
        String(Int64(Date().timeIntervalSince1970 * 1_000))
    }

    private static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func languageCode(for language: String, allowsAutomatic: Bool) -> String? {
        if language == LanguageCatalog.automatic { return allowsAutomatic ? "auto" : nil }
        return LanguageCatalog.language(language)?.youdaoCode
    }
}
