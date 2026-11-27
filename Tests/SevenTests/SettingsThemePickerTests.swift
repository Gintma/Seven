import AppKit
import SwiftUI
import XCTest
@testable import Seven

@MainActor
final class SettingsThemePickerTests: XCTestCase {
    func testNativeMenuSelectionAppliesToItsOwnAppearance() throws {
        _ = NSApplication.shared
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: "ThemePicker-" + UUID().uuidString))
        let manager = ThemeManager(defaults: defaults)
        let light = try makePicker(for: .light, manager: manager)
        let dark = try makePicker(for: .dark, manager: manager)
        defer {
            light.window.close()
            dark.window.close()
        }

        try chooseTheme("github", in: light.button)
        try chooseTheme("codex", in: dark.button)
        XCTAssertEqual(manager.themeID(for: .light), "github")
        XCTAssertEqual(manager.themeID(for: .dark), "codex")

        try chooseTheme(ThemePalette.systemID, in: light.button)
        XCTAssertEqual(manager.themeID(for: .light), ThemePalette.systemID)
        XCTAssertEqual(manager.themeID(for: .dark), "codex")
    }

    private func makePicker(for variant: ThemeVariant, manager: ThemeManager)
        throws -> (window: NSWindow, button: NSPopUpButton) {
        let root = NSHostingView(rootView: SettingsThemePickerRow(variant: variant, manager: manager))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        return (window, try XCTUnwrap(popUpButton(in: root)))
    }

    private func popUpButton(in view: NSView) -> NSPopUpButton? {
        if let button = view as? NSPopUpButton { return button }
        return view.subviews.lazy.compactMap { self.popUpButton(in: $0) }.first
    }

    private func chooseTheme(_ id: String, in button: NSPopUpButton) throws {
        let item = try XCTUnwrap(button.itemArray.first { ($0.representedObject as? String) == id })
        button.select(item)
        XCTAssertEqual(item.state, .on)
        XCTAssertTrue(button.sendAction(try XCTUnwrap(button.action), to: button.target))
    }
}
