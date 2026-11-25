import AppKit
import SwiftUI

struct SettingsEditableTextField: NSViewRepresentable {
    enum Style {
        case regular
        case key(revealed: Bool)
    }

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    let title: String
    var placeholder = ""
    var style: Style = .regular
    var autofocus = false
    var onSubmit: () -> Void = {}
    var onEndEditing: () -> Void = {}
    var onEditingChange: (Bool) -> Void = { _ in }

    static var keyHeight: CGFloat { NSLayoutManager().defaultLineHeight(for: Design.Settings.controlFont) * 2 + Design.Space.m }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField
        if case .key(revealed: false) = style {
            field = NSSecureTextField()
        } else {
            field = NSTextField()
        }
        field.delegate = context.coordinator
        field.controlSize = .regular
        field.font = Design.Settings.controlFont
        field.bezelStyle = .roundedBezel
        if case .key = style {
            field.maximumNumberOfLines = 2
            field.lineBreakMode = .byCharWrapping
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.cell?.usesSingleLineMode = false
        } else {
            field.cell?.isScrollable = true
            field.cell?.usesSingleLineMode = true
        }
        context.coordinator.focusRing = SettingsFieldFocusRing(editor: field, in: field, autofocus: autofocus)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = isEnabled
        field.setAccessibilityLabel(title)
        field.applyTheme(theme, placeholder: placeholder)
        context.coordinator.focusRing?.applyTheme(theme)
        let hasMarkedText = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !hasMarkedText, field.stringValue != text { field.stringValue = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.fittingSize.width
        if case .key = style { return CGSize(width: width, height: Self.keyHeight) }
        return CGSize(width: width, height: Design.Settings.controlHeight)
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        nsView.delegate = nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SettingsEditableTextField
        var focusRing: SettingsFieldFocusRing?

        init(_ parent: SettingsEditableTextField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.onEditingChange(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onEditingChange(false)
            parent.onEndEditing()
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}
