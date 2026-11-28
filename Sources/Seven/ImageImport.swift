import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Import reads only user-selected local images or clipboard images; no screen capture, file writes, or logging of paths or contents.
enum ImageImportError: LocalizedError {
    case noImage, unreadable, tooLarge, multipleFiles
    var errorDescription: String? {
        switch self {
        case .noImage: return L10n.text("theClipboardHasNoImageCopyAn")
        case .unreadable: return L10n.text("couldNotReadThisImageChooseAnother")
        case .tooLarge: return L10n.text("thisImageIsTooLargeResizeIt")
        case .multipleFiles: return L10n.text("openOneImageAtATime")
        }
    }
}

@MainActor enum ImageImport {
    static let supportedTypes: [UTType] = [.png, .jpeg, .heic, .tiff, .bmp, .gif, .webP]
    static func file(_ url: URL) throws -> NSImage {
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?,
              supportedTypes.contains(where: { $0.identifier == type }),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = metadata[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = metadata[kCGImagePropertyPixelHeight] as? NSNumber else { throw ImageImportError.unreadable }
        guard width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= Double(ScreenshotScrollPolicy.maximumPixels) else { throw ImageImportError.tooLarge }
        // First frame rotated to proper EXIF orientation; keep raw pixels rather than treating print DPI as canvas size.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width.intValue, height.intValue)]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ImageImportError.unreadable }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    static func clipboardFileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    static func clipboard(_ pasteboard: NSPasteboard, preservingLogicalSize: Bool = false) throws -> NSImage {
        // Finder puts both the file URL and its icon bitmap on the pasteboard; generic NSImage reading picks the icon.
        // Resolve file references first; report an error if unreadable rather than falling back to the icon or file path text.
        let files = clipboardFileURLs(pasteboard)
        if !files.isEmpty {
            guard files.count == 1, let url = files.first else { throw ImageImportError.multipleFiles }
            return try file(url)
        }
        guard let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
              let cg = ScreenshotSaving.cgImage(image) else { throw ImageImportError.noImage }
        guard Double(cg.width) * Double(cg.height) <= Double(ScreenshotScrollPolicy.maximumPixels) else { throw ImageImportError.tooLarge }
        return preservingLogicalSize ? image : NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// Shortcut entry shares the same registration, conflict, and persistence rules; claims no global hotkey by default.
@MainActor final class ImageEntryShortcuts {
    let scroll: HotKeyManager
    let file: HotKeyManager
    let clipboard: HotKeyManager
    init(defaults: UserDefaults? = .standard) {
        scroll = HotKeyManager(defaults: defaults, storageKey: "scrollCaptureHotKey.v1", identifierID: 15, actionLabel: "长截图", allowsUnset: true)
        file = HotKeyManager(defaults: defaults, storageKey: "openImageHotKey.v1", identifierID: 16, actionLabel: "打开本地图片", allowsUnset: true)
        clipboard = HotKeyManager(defaults: defaults, storageKey: "openClipboardImageHotKey.v1", identifierID: 17, actionLabel: "打开剪贴板图片", allowsUnset: true)
    }
    var managers: [HotKeyManager] { [scroll, file, clipboard] }
}
