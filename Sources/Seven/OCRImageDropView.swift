import AppKit

/// Accepts only user-dropped files, ignoring text or remote URLs; contents are still validated by the unified image importer.
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
