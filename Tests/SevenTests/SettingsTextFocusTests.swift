import AppKit
import SwiftUI
import XCTest
@testable import Seven

private final class SettingsFocusWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

private struct SettingsFocusFixture: View {
    let palette: ThemePalette
    let onSubmit: () -> Void
    let onEndEditing: () -> Void

    var body: some View {
        VStack {
            SettingsInputRow(title: "Endpoint", text: .constant("https://api.example.com/v1"),
                             onSubmit: onSubmit, onEndEditing: onEndEditing)
            SettingsKeyRow(title: "API Key", text: .constant(""), focused: .constant(false), reveal: {}, onSubmit: {})
            SettingsKeyRow(title: "Visible API Key", text: .constant(""), focused: .constant(false),
                           isRevealed: true, reveal: {}, onSubmit: {})
            SettingsLanguageSearch(text: .constant(""))
            SettingsPromptEditor(text: .constant(""), placeholder: "", accessibilityLabel: "Prompt")
                .frame(height: 100)
        }
        .environment(\.theme, palette)
        .frame(width: 360)
    }
}

@MainActor
final class SettingsTextFocusTests: XCTestCase {
    func testSettingsTextFieldsKeepKeyboardFocusWithoutFocusRings() async throws {
        _ = NSApplication.shared
        let custom = ThemePreset.resolve("codex", for: .light).palette(for: .light)
        XCTAssertFalse(custom.isSystem)
        var submissions = 0
        var ended = 0
        func fixture(_ palette: ThemePalette) -> SettingsFocusFixture {
            SettingsFocusFixture(palette: palette, onSubmit: { submissions += 1 }, onEndEditing: { ended += 1 })
        }
        let host = NSHostingView(rootView: fixture(.system))
        let window = SettingsFocusWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
                                         styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let children = screenshotDescendants(of: host)
        let fields = children.compactMap { $0 as? NSTextField }
        let address = try XCTUnwrap(fields.first { $0.accessibilityLabel() == "Endpoint" })
        let secure = try XCTUnwrap(fields.compactMap { $0 as? NSSecureTextField }.first)
        let revealed = try XCTUnwrap(fields.first { $0.accessibilityLabel() == "Visible API Key" })
        let search = try XCTUnwrap(fields.compactMap { $0 as? NSSearchField }.first)
        let prompt = try XCTUnwrap(children.compactMap { ($0 as? SettingsPromptScrollView)?.documentView }.first as? NSTextView)
        let editors: [NSView] = [address, secure, revealed, search, prompt]
        let deadline = ContinuousClock.now + .seconds(1)
        while search.currentEditor() == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(window.firstResponder === (try XCTUnwrap(search.currentEditor())))

        window.recalculateKeyViewLoop()
        XCTAssertTrue(window.makeFirstResponder(address))
        let fieldEditor = try XCTUnwrap(address.currentEditor() as? NSTextView)
        fieldEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submissions, 1)
        fieldEditor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        let secureEditor = try XCTUnwrap(secure.currentEditor())
        XCTAssertTrue(window.firstResponder === secureEditor)
        XCTAssertEqual(ended, 1)
        for editor in editors {
            XCTAssertEqual(editor.focusRingType, .none)
        }

        host.rootView = fixture(custom)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.firstResponder === secureEditor)
        for editor in editors {
            XCTAssertEqual(editor.focusRingType, .none)
        }
    }
}
