import AppKit
import SwiftUI
import XCTest
@testable import Seven

private final class SettingsFocusWindow: NSWindow {
    var simulatedKeyStatus = true
    override var isKeyWindow: Bool { simulatedKeyStatus }
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
    private func waitForFocusRing(_ ring: SettingsFieldFocusRing, visible: Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while ring.isHidden == visible && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(ring.isHidden, !visible)
    }

    func testThemedFocusFollowsSettingsFieldEditorsAndWindowActivation() async throws {
        _ = NSApplication.shared
        let custom = ThemePreset.resolve("codex", for: .light).palette(for: .light)
        XCTAssertFalse(custom.isSystem)
        var submissions = 0
        var ended = 0
        func fixture(_ palette: ThemePalette) -> SettingsFocusFixture {
            SettingsFocusFixture(palette: palette, onSubmit: { submissions += 1 }, onEndEditing: { ended += 1 })
        }
        let host = NSHostingView(rootView: fixture(custom))
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
        let containers = [address, secure, revealed, search, try XCTUnwrap(prompt.enclosingScrollView?.superview)] as [NSView]
        let rings = try containers.map { container in
            try XCTUnwrap(container.subviews.compactMap { $0 as? SettingsFieldFocusRing }.first)
        }
        // 添加语言弹窗原有的自动聚焦，也要在首次键入前显示描边。
        try await waitForFocusRing(rings[3], visible: true)
        for (index, editor) in editors.enumerated() {
            XCTAssertTrue(window.makeFirstResponder(editor))
            try await waitForFocusRing(rings[index], visible: true)
            XCTAssertEqual(rings.filter { !$0.isHidden }.count, 1)
            XCTAssertEqual(editor.focusRingType, .none)
            if editor === address {
                let fieldEditor = try XCTUnwrap(address.currentEditor() as? NSTextView)
                fieldEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                XCTAssertEqual(submissions, 1)
            }
        }
        XCTAssertEqual(ended, 1)

        window.simulatedKeyStatus = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertTrue(rings[4].isHidden)
        window.simulatedKeyStatus = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertFalse(rings[4].isHidden)

        XCTAssertTrue(window.makeFirstResponder(address))
        try await waitForFocusRing(rings[0], visible: true)
        host.rootView = fixture(.system)
        host.layoutSubtreeIfNeeded()
        try await waitForFocusRing(rings[0], visible: false)
        XCTAssertEqual(address.focusRingType, .default)
        XCTAssertTrue(window.firstResponder === address.currentEditor())
    }
}
