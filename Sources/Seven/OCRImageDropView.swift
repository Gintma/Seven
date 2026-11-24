import AppKit

/// 只接收用户拖入的文件，不读取文字或远程URL；内容仍交给统一图片导入器校验。
final class OCRImageDropView: NSView {
    var onOpenFiles: (([URL]) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { nil }
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        ImageImport.clipboardFileURLs(pasteboard)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onOpenFiles?(urls); return true
    }
}
