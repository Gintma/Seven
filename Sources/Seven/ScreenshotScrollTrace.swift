import Foundation
import CoreGraphics

/// Opt-in scrolling-screenshot diagnostics. Records only geometry, timings, and fixed categories; never accepts images or text.
struct ScreenshotScrollTrace: Sendable {
    static let enabledKey = "screenshotScrollDiagnostics.v1"
    static let directory = URL(filePath: "/tmp/seven-scroll-diagnostics", directoryHint: .isDirectory)
    enum Kind: String, Codable { case started, wheel, sampleStarted, sampleFinished, discarded, captureFailed, reset, finished, cancelled }
    struct Entry: Codable, Sendable {
        let time: Double
        let kind: Kind
        let sequence: Int?
        let generation: UUID?
        let rect: CGRect?
        let pixelWidth: Int?
        let pixelHeight: Int?
        let scale: Double?
        let wheelDeltaY: Double?
        let elapsedMS: Double?
        let match: ScreenshotScrollMatchInfo?
    }
    let fileURL: URL
    private let queue = DispatchQueue(label:"Seven.ScrollCaptureTrace")
    static func start(defaults:UserDefaults, directory:URL = directory)->Self? {
#if DEBUG || SEVEN_DEVELOPMENT
        guard defaults.bool(forKey:enabledKey) else { return nil }
        return try? Self(directory:directory)
#else
        return nil
#endif
    }
    init(directory:URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.fileSystemPath)
        fileURL = directory.appending(path: "session-\(UUID().uuidString).jsonl", directoryHint: .checkFileSystem)
        try Data().write(to:fileURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:fileURL.fileSystemPath)
    }
    func record(_ kind:Kind,sequence:Int? = nil,generation:UUID? = nil,rect:CGRect? = nil,pixelWidth:Int? = nil,pixelHeight:Int? = nil,
                scale:Double? = nil,wheelDeltaY:Double? = nil,elapsedMS:Double? = nil,match:ScreenshotScrollMatchInfo? = nil) {
        let entry = Entry(time:ProcessInfo.processInfo.systemUptime,kind:kind,sequence:sequence,generation:generation,rect:rect,
            pixelWidth:pixelWidth,pixelHeight:pixelHeight,scale:scale,wheelDeltaY:wheelDeltaY,elapsedMS:elapsedMS,match:match)
        guard var data = try? JSONEncoder().encode(entry) else { return }
        data.append(0x0a)
        let line = data,url = fileURL
        queue.async {
            guard let handle = try? FileHandle(forWritingTo:url) else { return }
            defer { try? handle.close() }
            do { try handle.seekToEnd();try handle.write(contentsOf:line) } catch { }
        }
    }
    /// Used only to await diagnostic flush so trailing events are not missed when reading the file after closing.
    func flushed() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
}
