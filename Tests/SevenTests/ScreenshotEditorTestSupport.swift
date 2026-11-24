import AppKit
import XCTest
@testable import Seven

@MainActor
func makeScreenshotEditorForTesting(
    image: NSImage,
    preferences: ScreenshotToolPreferences,
    toolbarPreferences: ScreenshotToolbarPreferences? = nil,
    clipboardWriter: ((NSImage) -> Bool)? = nil,
    soundPlayer: (() -> Void)? = nil
) -> ScreenshotEditorWindowController {
    let placement = CGRect(origin: .zero, size: image.size)
    let screen = CGRect(origin: .zero, size: CGSize(width: max(1600, image.size.width), height: max(1000, image.size.height)))
    let context = ScreenshotCenteredEditorContext(screenFrame: screen, background: nil, placement: placement)
    return ScreenshotEditorWindowController(image: image, context: .centered(context), preferences: preferences,
                                            toolbarPreferences: toolbarPreferences, clipboardWriter: clipboardWriter,
                                            soundPlayer: soundPlayer)
}

@MainActor
func screenshotEditorToolbarContent(_ editor: ScreenshotEditorWindowController) throws -> NSView {
    let toolbar = editor.window?.childWindows?.first { $0.title == L10n.text("screenshotToolbar") }
    return try XCTUnwrap(toolbar?.contentView)
}

@MainActor
func screenshotEditorTestSubviews(_ editor: ScreenshotEditorWindowController) throws -> [NSView] {
    func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
    let overlay = try XCTUnwrap(editor.window?.contentView)
    return descendants(overlay) + descendants(try screenshotEditorToolbarContent(editor))
}
