import Foundation
import XCTest

/// Source lint guard enforcing the original private / private(set) write boundaries after splitting the model into cross-file extensions.
final class TranslationModelStateLintTests: XCTestCase {
    private static let protectedProperties = [
        // Model-managed state; the service instance list replaces the legacy single config and configured flag.
        // Add new model-managed @Published state to this list by default, excluding intentionally writable properties like settings.
        "input", "detectedSource", "serviceResults", "isLoading",
        "status", "errorMessage", "serviceInstances", "recoveryAction",
        "primaryLanguage", "commonLanguages", "secondaryLanguage", "resolvedTarget",
        "isTestingConfiguration", "configurationTestMessage", "configurationTestSucceeded",
        "inputMaximumHeight", "maximumWindowHeightRatio", "panelScreenHeight",
        "expandedProviders", "appleTranslationRequest",
        // Mutable caches, detection state, and task handles from formerly private storage; excludes read-only injected dependencies and constants.
        "confirmedDetection", "localDetectionCache", "detectionTask", "detectingText", "isDetectingOnline",
        "translateAfterDetection", "retryAfterDetection", "serviceTasks",
        "configurationTestTask", "generation", "primaryResultID", "historyRound", "systemTranslationBridgeAvailable"
    ]

    private static func isModelFile(_ name: String) -> Bool {
        name == "TranslationModel.swift" || (name.hasPrefix("TranslationModel+") && name.hasSuffix(".swift"))
    }

    private static func writeRanges(in source: String) throws -> [NSRange] {
        let properties = protectedProperties.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let property = #"\.\s*(?:"# + properties + #")\b"#
        // Also checks subscript and member write-backs such as serviceResults[index].phase = and historyRound?.record =.
        let memberPath = #"(?:\s*\?\s*)?(?:\s*\[[^\]\n]*\]|\s*\??\.\s*[A-Za-z_][A-Za-z0-9_]*)*"#
        let mutatingMethod = #"(?:append\w*|insert\w*|remove\w*|replaceSubrange|replace|swapAt|sort|shuffle|reverse|formUnion|formIntersection|formSymmetricDifference|subtract|updateValue|merge|reserveCapacity|toggle|cancel)"#
        let patterns = [
            property + memberPath + #"\s*(?:=(?!=)|[+\-*/%&|^]=|&[+\-*]=)"#,
            property + memberPath + #"\s*\??\.\s*"# + mutatingMethod + #"\s*\("#,
            // $model.input is a writable binding; model.$serviceResults is a read-only Publisher and should not be blocked.
            // Local @State $primaryLanguage in Settings views is likewise not a model binding.
            #"\$[A-Za-z_][A-Za-z0-9_]*(?:\s*\??\.\s*[A-Za-z_][A-Za-z0-9_]*)*"# + property,
            #"(?:^|[(,:])\s*&(?!&)\s*[A-Za-z_][A-Za-z0-9_]*(?:\s*\??\.\s*[A-Za-z_][A-Za-z0-9_]*)*"# + property
        ]
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return try patterns.flatMap { pattern in
            try NSRegularExpression(pattern: pattern).matches(in: source, range: range).map(\.range)
        }
    }

    func testModelStateIsOnlyWrittenInsideTranslationModelFiles() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Seven")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ), "应能找到源码目录")
        let files = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !Self.isModelFile($0.lastPathComponent) }
            .sorted { $0.path < $1.path }
        XCTAssertGreaterThan(files.count, 10, "应能找到非模型源码文件")

        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in try Self.writeRanges(in: source) {
                let prefix = (source as NSString).substring(to: match.location)
                let line = prefix.filter { $0 == "\n" }.count + 1
                let path = file.path.replacingOccurrences(of: sources.path + "/", with: "")
                violations.append("\(path):\(line) 请通过 TranslationModel 的方法修改状态")
            }
        }
        XCTAssertTrue(violations.isEmpty, "\n" + violations.joined(separator: "\n"))
    }

    func testStateWriteRulesRejectMutationsAndAllowObservationAndLocalBindings() throws {
        for property in Self.protectedProperties {
            XCTAssertFalse(try Self.writeRanges(in: "model.\(property) = value").isEmpty, "应拦截：\(property)")
            XCTAssertFalse(try Self.writeRanges(in: "$model.\(property)").isEmpty, "应拦截绑定：\(property)")
        }
        for bad in [
            "model.status += suffix", "model.panelScreenHeight -= 1",
            "model?.serviceResults.append(result)", "model.expandedProviders.insert(provider)",
            "model.serviceTasks.removeAll()", "model.retryAfterDetection.removeFirst()",
            "model.serviceResults[0].phase = .loading", "model.historyRound?.record = code",
            "model.serviceTasks[provider]?.cancel()",
            "model.detectionTask?.cancel()", "model.isLoading.toggle()",
            "self.$model.input", "$holder.model.input", "mutate(&model.status)",
            "model\n .status\n = value"
        ] {
            XCTAssertFalse(try Self.writeRanges(in: bad).isEmpty, "应拦截：\(bad)")
        }
        for good in [
            "model.input == value", "model.input != value", "model.input.count >= 1",
            "model.serviceResults[0].phase == .success", "let value = model.status",
            "isCommon && model.commonLanguages.count == 1",
            "let flags = mask & model.inputMaximumHeight",
            "model.serviceResults.contains { $0.phase == .loading }",
            "model.$serviceResults.sink { _ in }", "model.$input.eraseToAnyPublisher()",
            "Picker(selection: $primaryLanguage)", "self.$primaryLanguage",
            "Toggle(isOn: $model.googleEnabled)", "model.updateInput(value)",
            "model.retryResult(provider)", "model.statusCopy = value"
        ] {
            XCTAssertTrue(try Self.writeRanges(in: good).isEmpty, "不应拦截：\(good)")
        }
        XCTAssertTrue(Self.isModelFile("TranslationModel.swift"))
        XCTAssertTrue(Self.isModelFile("TranslationModel+Requests.swift"))
        XCTAssertFalse(Self.isModelFile("TranslationModelStateGuardProbe.swift"))
    }
}
