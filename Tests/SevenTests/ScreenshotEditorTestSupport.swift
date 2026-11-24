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
    let childContent = (editor.window?.childWindows ?? []).compactMap(\.contentView)
    let toolbar = childContent.lazy.flatMap { [$0] + screenshotDescendants(of: $0) }
        .first { $0 is ScreenshotEditorToolbar }
    return try XCTUnwrap(toolbar)
}

@MainActor
func screenshotEditorTestSubviews(_ editor: ScreenshotEditorWindowController) throws -> [NSView] {
    let overlay = try XCTUnwrap(editor.window?.contentView)
    return screenshotDescendants(of: overlay) + screenshotDescendants(of: try screenshotEditorToolbarContent(editor))
}

@MainActor
func screenshotDescendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { screenshotDescendants(of: $0) }
}
