import Foundation
import XCTest

final class DocumentationIntegrityTests: XCTestCase {
    func testRepositoryLinksAndTaskRoutesResolve() throws {
        let files = FileManager.default
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let docs = root.appendingPathComponent("Docs", isDirectory: true)
        let entry = root.appendingPathComponent("AGENTS.md")
        let documents = try files.subpathsOfDirectory(atPath: docs.path)
            .filter { $0.lowercased().hasSuffix(".md") }
            .sorted()
            .map { docs.appendingPathComponent($0) }
        var routes = Set<String>()

        for file in [entry, root.appendingPathComponent("README.md"), root.appendingPathComponent("README.zh-CN.md")] + documents {
            let source = try String(contentsOf: file, encoding: .utf8)
            let markdown = try AttributedString(markdown: source, baseURL: file)
            for run in markdown.runs {
                for link in [run.link, run.imageURL].compactMap({ $0 }) where link.isFileURL {
                    let path = link.absoluteURL.standardizedFileURL.path
                    XCTAssertTrue(path.hasPrefix(root.path + "/") || path == root.path,
                                  "\(file.lastPathComponent) 中的链接超出了仓库：\(link.relativeString)")
                    XCTAssertTrue(files.fileExists(atPath: path),
                                  "\(file.lastPathComponent) 中的目标不存在：\(link.relativeString)")
                    if file == entry { routes.insert(path) }
                }
            }
        }

        let modulePages = documents.filter { $0.deletingLastPathComponent().lastPathComponent == "modules" }
        let overviews = ["Seven代码结构.md", "Seven设计规范.md"].map { docs.appendingPathComponent($0) }
        for page in overviews + modulePages {
            XCTAssertTrue(routes.contains(page.path), "AGENTS.md 缺少任务入口：\(page.lastPathComponent)")
        }
    }
}
