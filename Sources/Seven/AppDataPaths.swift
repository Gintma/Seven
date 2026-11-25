import Foundation
import CoreFoundation

/// 词库与通用诊断沿用共享目录。试用变体的凭据、翻译历史和收藏夹使用变体目录。
enum AppDataPaths {
    static func variant(bundleIdentifier: String?) -> String? {
        let prefix = "local.seven.translator."
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
    /// 系统文件路径保留编码的路径分隔符，避免把文件名误当成目录。
    var fileSystemPath: String {
        (CFURLCopyFileSystemPath(self as CFURL, .cfurlposixPathStyle) as String?) ?? ""
    }
}
