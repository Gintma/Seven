import Foundation
import XCTest

/// Shared state across AppDelegate extension files; other sources must access it through composition root action entry points.
final class AppDelegateStateLintTests: XCTestCase {
    // Lists only mutable stored properties widened from private to internal during file splitting that are still retained.
    // model, inputReplacement, and settings/history windows remain private(set) and do not need duplicate setter guards.
    private static let protectedProperties = [
        "item", "panel", "selectionMenuItem", "screenshotMenuItem",
        "localKeyMonitor", "selectionTask", "selectionGate", "screenshotTask", "screenshotGate",
        "hasRememberedPanelPosition", "preferredPanelHeight",
        "replacementMenuItem", "inputMenuItem", "screenshotEditors", "scrollCapture", "ocrWindowController", "imageEntriesReady", "pendingImageURLs"
    ]

    private static func isOwnerFile(_ name: String) -> Bool {
        name == "App.swift" || (name.hasPrefix("AppDelegate+") && name.hasSuffix(".swift"))
    }

    private static func writeRanges(in source: String) throws -> [NSRange] {
        let names = protectedProperties.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let property = #"\b([A-Za-z_][A-Za-z0-9_]*)\s*\??\.\s*("# + names + #")\b"#
        let path = #"(?:\s*\[[^\]\n]*\]|\s*\??\.\s*[A-Za-z_][A-Za-z0-9_]*)*"#
        let mutations = #"(?:append\w*|insert\w*|remove\w*|toggle|cancel|begin|finish|invalidate|setFrame\w*|order\w*|makeKeyAndOrderFront|refreshWindowLayout)"#
        let patterns = [
            property + path + #"\s*(?:=(?!=)|[+\-*/%&|^]=)"#,
            property + path + #"\s*\??\.\s*"# + mutations + #"\s*\("#,
            #"\$"# + property,
            #"(?:^|[(,:])\s*&\s*"# + property
        ]
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return try patterns.flatMap { pattern in
            try NSRegularExpression(pattern: pattern).matches(in: source, range: range).filter { match in
                let receiver = (source as NSString).substring(with: match.range(at: 1))
                let name = (source as NSString).substring(with: match.range(at: 2))
                // Types such as ScreenshotCapture have their own self.panel.
                // Allow only same-named self members declared in source; external writes like delegate.panel must still be blocked.
                let ownDeclaration = #"\b(?:let|var)\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#
                return receiver != "self" || source.range(of: ownDeclaration, options: .regularExpression) == nil
            }.map(\.range)
        }
    }

    func testAppDelegateStateIsOnlyWrittenInsideOwnerFiles() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Seven")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ))
        let files = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !Self.isOwnerFile($0.lastPathComponent) }
        XCTAssertGreaterThan(files.count, 10, "应能找到非 AppDelegate 源码")
        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in try Self.writeRanges(in: source) {
                let line = (source as NSString).substring(to: match.location).filter { $0 == "\n" }.count + 1
                violations.append("\(file.lastPathComponent):\(line) 请通过 AppDelegate 的方法修改状态")
            }
        }
        XCTAssertTrue(violations.isEmpty, "\n" + violations.joined(separator: "\n"))
    }

    func testStartupDoesNotCreateOrShowTranslationPanel() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Seven/App.swift")
        let code = try String(contentsOf: source, encoding: .utf8)
        let start = try XCTUnwrap(code.range(of: "func applicationDidFinishLaunching"))
        let end = try XCTUnwrap(code.range(of: "func applicationShouldTerminate"))
        let launch = code[start.lowerBound..<end.lowerBound]
        XCTAssertFalse(launch.contains("setupTranslationPanel("))
        XCTAssertFalse(launch.contains("showPanel("))
    }

    func testStateGuardRejectsExternalWritesAndAllowsOtherTypesOwnState() throws {
        for name in Self.protectedProperties {
            XCTAssertFalse(try Self.writeRanges(in: "delegate.\(name) = value").isEmpty, "应拦截：\(name)")
        }
        for bad in [
            "delegate.preferredPanelHeight += delta", "delegate.selectionTask?.cancel()",
            "delegate.selectionGate.invalidate()", "delegate.panel.setFrame(frame, display: true)",
            "delegate.panel.frame = frame", "$delegate.preferredPanelHeight", "mutate(&delegate.panel)",
            "self.delegate.panel = panel", "let panel: NSPanel?; delegate.panel = panel"
        ] {
            XCTAssertFalse(try Self.writeRanges(in: bad).isEmpty, "应拦截：\(bad)")
        }
        for good in [
            "delegate.panel == current", "let height = delegate.preferredPanelHeight",
            "private var panel: NSPanel?; self.panel = panel", "let inputMenuItem: NSMenuItem; self.inputMenuItem = item",
            "delegate.showPanel()", "delegate.windowShouldClose(panel)"
        ] {
            XCTAssertTrue(try Self.writeRanges(in: good).isEmpty, "不应拦截：\(good)")
        }
        XCTAssertTrue(Self.isOwnerFile("App.swift"))
        XCTAssertTrue(Self.isOwnerFile("AppDelegate+Panel.swift"))
        XCTAssertFalse(Self.isOwnerFile("AppDelegateStateGuardProbe.swift"))
    }
}
