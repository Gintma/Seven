import Foundation
import CoreFoundation

/// Dictionaries and general diagnostics use the shared directory. Preview variants store credentials, translation history, and favorites in the variant directory.
enum AppDataPaths {
    static let bundleIdentifier = "com.crissun.seven"

    static func variant(bundleIdentifier: String?) -> String? {
        let prefix = Self.bundleIdentifier + "."
        guard let bundleIdentifier, bundleIdentifier.hasPrefix(prefix) else { return nil }
        let suffix = String(bundleIdentifier.dropFirst(prefix.count))
        guard !suffix.isEmpty, suffix.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { return nil }
        return suffix
    }
    static func directory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, variant: String? = nil) -> URL {
        homeDirectory.appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: "Seven" + (variant.map { "-" + $0 } ?? ""), directoryHint: .isDirectory)
    }
}

extension URL {
    /// Preserve encoded path separators in file paths so filenames are not mistaken for directories.
    var fileSystemPath: String {
        (CFURLCopyFileSystemPath(self as CFURL, .cfurlposixPathStyle) as String?) ?? ""
    }
}
