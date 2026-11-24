import Foundation
import SQLite3
import XCTest
@testable import Seven

final class ECDictionaryTests: XCTestCase {
    func testQueryNormalizationAcceptsWordsAndShortPhrasesOnly() {
        XCTAssertEqual(ECDictionaryService.normalizedQuery(" Refine, "), "Refine")
        XCTAssertEqual(ECDictionaryService.normalizedQuery("look forward to"), "look forward to")
        XCTAssertNil(ECDictionaryService.normalizedQuery("苹果"))
        XCTAssertNil(ECDictionaryService.normalizedQuery("中英 mixed"))
        XCTAssertNil(ECDictionaryService.normalizedQuery("This sentence contains enough words to be translation text."))
        XCTAssertNil(ECDictionaryService.normalizedQuery("first line\nsecond line"))
    }

    func testEntryParserBuildsDefinitionsFormsAndLabels() {
        let entry = ECDictionaryEntryParser.parse(ECDictionaryRecord(
            word: "refine",
            phonetic: "ri'fain",
            definition: "v. improve by making small changes\nv. purify",
            translation: "vt. 精炼, 净化\nvi. 改进",
            pos: "v:100",
            collins: 2,
            oxford: true,
            tag: "cet4 cet6 ielts",
            bnc: 7_830,
            frq: 6_600,
            exchange: "i:refining/d:refined/p:refined/3:refines"
        ))

        XCTAssertEqual(entry.headword, "refine")
        XCTAssertEqual(entry.pronunciations, [.init(label: "音标", value: "ri'fain")])
        XCTAssertEqual(entry.blocks.map(\.text), ["vt. 精炼, 净化", "vi. 改进"])
        XCTAssertEqual(entry.englishDefinitions.count, 2)
        XCTAssertEqual(entry.forms.map(\.label), ["现在分词", "过去分词", "过去式", "第三人称单数"])
        XCTAssertTrue(entry.labels.contains("四级"))
        XCTAssertTrue(entry.labels.contains("牛津 3000"))
        XCTAssertTrue(entry.labels.contains("柯林斯 2 星"))
    }

    func testEntryParserRestoresEscapedNewlinesFromOfficialCSV() {
        let entry = ECDictionaryEntryParser.parse(ECDictionaryRecord(
            word: "refine", phonetic: "ri'fain",
            definition: "v. improve\\nv. purify",
            translation: "vt. 精炼\\nvi. 被精炼",
            pos: "v:100", collins: 0, oxford: false, tag: "",
            bnc: nil, frq: nil, exchange: ""
        ))

        XCTAssertEqual(entry.blocks.map(\.text), ["vt. 精炼", "vi. 被精炼"])
        XCTAssertEqual(entry.englishDefinitions, ["v. improve", "v. purify"])
    }

    func testLemmaRelationshipCodeIsNotDisplayedAsAWordForm() {
        let entry = ECDictionaryEntryParser.parse(ECDictionaryRecord(
            word: "gave", phonetic: "geiv", definition: "v. give",
            translation: "give的过去式", pos: "v:100", collins: 0,
            oxford: false, tag: "", bnc: nil, frq: nil,
            exchange: "0:give/1:p"
        ))

        XCTAssertEqual(entry.forms, [.init(id: 0, label: "原形", value: "give")])
    }

    func testCSVImporterPreservesQuotedNewlinesAndSupportsExactAndFuzzyQueries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenECDICTTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let csvURL = directory.appendingPathComponent("ecdict.csv")
        let databaseURL = directory.appendingPathComponent("ecdict.sqlite3")
        let csv = """
        word,phonetic,definition,translation,pos,collins,oxford,tag,bnc,frq,exchange,detail,audio
        refine,ri'fain,"v. improve by making small changes\nv. purify","vt. 精炼, 净化\nvi. 改进",v:100,2,1,"cet4 cet6 ielts",7830,6600,"i:refining/d:refined/p:refined/3:refines",,
        long-time,lɔŋtaim,n. a long period,n. 长期的,n:100,0,0,,100,200,,,
        "quoted, word",kwəʊtɪd,n. comma test,n. 逗号测试,n:100,0,0,,,,s:quoted words,,

        """
        try Data(csv.utf8).write(to: csvURL)

        let count = try ECDictionaryImporter.importCSV(from: csvURL, to: databaseURL) { _, _ in }

        XCTAssertEqual(count, 3)
        XCTAssertEqual(try ECDictionaryDatabase.query(url: databaseURL, word: "REFINE")?.translation, "vt. 精炼, 净化\nvi. 改进")
        XCTAssertEqual(try ECDictionaryDatabase.query(url: databaseURL, word: "long time")?.word, "long-time")
        XCTAssertEqual(try ECDictionaryDatabase.query(url: databaseURL, word: "quoted, word")?.translation, "n. 逗号测试")
        XCTAssertEqual(ECDictionaryDatabase.metadata(url: databaseURL)?.count, 3)
    }

    func testUnavailableDatabaseDoesNotReturnAResult() async throws {
        let service = ECDictionaryService(
            databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )

        XCTAssertFalse(service.isAvailable)
        let result = try await service.lookup("refine")
        XCTAssertNil(result)
    }

    func testFailedDatabaseOpenClosesReturnedHandle() throws {
        let handle = try XCTUnwrap(OpaquePointer(bitPattern: 1))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ecdict.sqlite3")
        var closedHandles: [OpaquePointer] = []
        let database = ECDictionaryDatabase.open(
            url: url, flags: SQLITE_OPEN_READONLY,
            openConnection: { _, database, _, _ in
                database.pointee = handle
                return SQLITE_CANTOPEN
            },
            closeConnection: { database in
                closedHandles.append(database)
                return SQLITE_OK
            }
        )

        XCTAssertNil(database)
        XCTAssertEqual(closedHandles, [handle])
    }

    func testSuccessfulDatabaseOpenReturnsHandleWithoutClosingIt() throws {
        let handle = try XCTUnwrap(OpaquePointer(bitPattern: 1))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ecdict.sqlite3")
        let database = ECDictionaryDatabase.open(
            url: url, flags: SQLITE_OPEN_READONLY,
            openConnection: { _, database, _, _ in
                database.pointee = handle
                return SQLITE_OK
            },
            closeConnection: { _ in
                XCTFail("打开成功后应将句柄交给调用方关闭")
                return SQLITE_OK
            }
        )

        XCTAssertEqual(database, handle)
    }

    func testCorruptDatabaseThrowsInsteadOfReportingWordNotFound() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try Data("not a sqlite database".utf8).write(to: databaseURL)
        let service = ECDictionaryService(databaseURL: databaseURL)

        do {
            _ = try await service.lookup("refine")
            XCTFail("损坏的词库应当抛出错误，而不是返回未收录")
        } catch {
            XCTAssertTrue(error is ECDictionaryError)
        }
    }

    func testStripWordNormalizesPunctuationAndSpacing() {
        XCTAssertEqual(ECDictionaryDatabase.stripWord("Long-Time"), "longtime")
        XCTAssertEqual(ECDictionaryDatabase.stripWord("long time"), "longtime")
        XCTAssertEqual(ECDictionaryDatabase.stripWord("O'Reilly"), "oreilly")
    }
}
