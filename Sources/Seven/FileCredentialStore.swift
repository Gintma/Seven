import Foundation
import Darwin

enum FileCredentialError: LocalizableIssue {
    case unreadable, unsafePath, writeFailed
    case invalidFormat(URL)
    var issue: LocalizedMessage {
        switch self {
        case .unreadable: return .key("couldNotReadTheLocalCredentialFile")
        case .invalidFormat(let url): return .key("theCredentialFileIsDamagedDeleteIt", .text(String(describing: url.fileSystemPath)))
        case .unsafePath: return .key("theLocalCredentialPathIsInvalidCheck")
        case .writeFailed: return .key("couldNotSaveTheLocalCredentialYour")
        }
    }
}

/// 明文凭据只在独立文件中存储；原子替换、跨进程文件锁，不参与设置/历史/诊断导出。
struct FileCredentialStore: CredentialStoring {
    struct Document: Codable {
        var version = 1
        var keys: [String: String] = [:]

    }
    let directory: URL
    var fileURL: URL { directory.appending(path: "credentials.json", directoryHint: .checkFileSystem) }
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }
    static func defaultDirectory(homeDirectory: URL, bundleIdentifier: String?) -> URL {
        AppDataPaths.directory(homeDirectory: homeDirectory, variant: AppDataPaths.variant(bundleIdentifier: bundleIdentifier))
    }

    private func instanceID(_ account: String) -> String? {
        let prefix = "service-instance.v1."
        guard account.hasPrefix(prefix), account.count > prefix.count else { return nil }
        return String(account.dropFirst(prefix.count))
    }
    func read(account: String) throws -> String {
        guard let id = instanceID(account) else { return "" }
        return try transaction { document in document.keys[id] ?? "" }
    }
    func save(_ value: String, account: String) throws {
        guard let id = instanceID(account) else {
            // 文件只接受实例账户。
            guard value.isEmpty else { throw FileCredentialError.invalidFormat(fileURL) }
            return
        }
        try transaction(write: true) { document in
            if value.isEmpty { document.keys.removeValue(forKey: id) } else { document.keys[id] = value }
        }
    }
    private func transaction<T>(write: Bool = false, _ action: (inout Document) throws -> T) throws -> T {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var directoryInfo = stat()
        guard lstat(directory.fileSystemPath, &directoryInfo) == 0, directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == getuid() else { throw FileCredentialError.unsafePath }
        guard chmod(directory.fileSystemPath, 0o700) == 0 else { throw FileCredentialError.writeFailed }
        let lockURL = directory.appending(path: "credentials.lock", directoryHint: .checkFileSystem)
        let descriptor = open(lockURL.fileSystemPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw FileCredentialError.unreadable }
        defer { close(descriptor) }
        try validate(descriptor)
        guard flock(descriptor, LOCK_EX) == 0 else { throw FileCredentialError.unreadable }
        defer { flock(descriptor, LOCK_UN) }
        var document = try load()
        let result = try action(&document)
        if write { try replace(document) }
        return result
    }
    private func validate(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            throw FileCredentialError.unsafePath
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw FileCredentialError.writeFailed }
    }
    private func load() throws -> Document {
        let descriptor = open(fileURL.fileSystemPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return Document() }
            throw FileCredentialError.unreadable
        }
        defer { close(descriptor) }
        try validate(descriptor)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw FileCredentialError.unreadable }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 else {
            throw FileCredentialError.invalidFormat(fileURL)
        }
        return document
    }
    private func replace(_ document: Document) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        let temporary = directory.appending(path: ".credentials-\(UUID().uuidString).tmp", directoryHint: .checkFileSystem)
        let descriptor = open(temporary.fileSystemPath, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw FileCredentialError.writeFailed }
        defer { close(descriptor); unlink(temporary.fileSystemPath) }
        try validate(descriptor)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw FileCredentialError.writeFailed }
                guard count > 0 else { throw FileCredentialError.writeFailed }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.fileSystemPath, fileURL.fileSystemPath) == 0 else { throw FileCredentialError.writeFailed }
        let parent = open(directory.fileSystemPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw FileCredentialError.writeFailed }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw FileCredentialError.writeFailed }
    }
}
