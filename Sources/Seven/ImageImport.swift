import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 导入只读用户主动选择的本地图片或剪贴板图片；不采屏、不写文件、不记录路径或内容。
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
        // 首帧，按EXIF旋转到正确方向；保持原像素，不把打印DPI当作编辑画布尺寸。
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
        // Finder同时提供文件地址和图标位图，NSImage的通用读取会挑到图标。
        // 文件引用必须先解析；打不开时报告错误，不能退回图标或文件路径文字。
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

/// 快捷入口沿用同一注册/冲突/持久化规则；默认不占用任何全局组合键。
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
