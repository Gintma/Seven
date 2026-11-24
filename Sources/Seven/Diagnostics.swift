import Foundation

enum DiagnosticLevel: String, Sendable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

protocol DiagnosticLogging: Sendable {
    var fileURL: URL { get }
    func record(_ level: DiagnosticLevel, _ event: String, metadata: [String: String]) async
    func contents() async -> String
    func clear() async
}

struct NoopDiagnosticLogger: DiagnosticLogging {
    let fileURL = URL(filePath: "/dev/null", directoryHint: .checkFileSystem)
    func record(_ level: DiagnosticLevel, _ event: String, metadata: [String: String]) async {}
    func contents() async -> String { "" }
    func clear() async {}
}

final class FileDiagnosticLogger: DiagnosticLogging, @unchecked Sendable {
    static let shared = FileDiagnosticLogger()

    let fileURL: URL
    private let queue = DispatchQueue(label: "local.seven.diagnostics")
    private let maximumBytes = 512 * 1_024

    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appending(path: "Seven", directoryHint: .isDirectory)
        fileURL = root.appending(path: "diagnostics.log", directoryHint: .checkFileSystem)
    }

    func record(_ level: DiagnosticLevel, _ event: String, metadata: [String: String] = [:]) async {
        await withCheckedContinuation { continuation in
            queue.async { [fileURL, maximumBytes] in
                let manager = FileManager.default
                do {
                    try manager.createDirectory(
                        at: fileURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if let size = try? manager.attributesOfItem(atPath: fileURL.fileSystemPath)[.size] as? Int,
                       size >= maximumBytes {
                        let previous = fileURL.deletingLastPathComponent().appending(path: "diagnostics.previous.log", directoryHint: .checkFileSystem)
                        try? manager.removeItem(at: previous)
                        try? manager.moveItem(at: fileURL, to: previous)
                    }
                    let timestamp = ISO8601DateFormatter().string(from: Date())
                    let fields = metadata.keys.sorted().map { key in
                        "\(Self.clean(key))=\(Self.clean(metadata[key] ?? ""))"
                    }
                    let suffix = fields.isEmpty ? "" : " " + fields.joined(separator: " ")
                    let line = "\(timestamp) [\(level.rawValue)] \(Self.clean(event))\(suffix)\n"
                    let data = Data(line.utf8)
                    if manager.fileExists(atPath: fileURL.fileSystemPath),
                       let handle = try? FileHandle(forWritingTo: fileURL) {
                        try handle.seekToEnd()
                        try handle.write(contentsOf: data)
                        try handle.close()
                    } else {
                        try data.write(to: fileURL, options: .atomic)
                    }
                } catch {
                    // Diagnostics must never interrupt translation.
                }
                continuation.resume()
            }
        }
    }

    func contents() async -> String {
        await withCheckedContinuation { continuation in
            queue.async { [fileURL] in
                let value = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                continuation.resume(returning: value)
            }
        }
    }

    func clear() async {
        await withCheckedContinuation { continuation in
            queue.async { [fileURL] in
                try? Data().write(to: fileURL, options: .atomic)
                continuation.resume()
            }
        }
    }

    private static func clean(_ value: String) -> String {
        String(value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(400))
    }
}
