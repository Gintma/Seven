import AppKit
import SwiftUI

/// Fixed-height native multiline editor; placeholder text is drawn only and never inserted into text storage or the binding.
struct SettingsPromptEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SettingsPromptScrollView {
        let scroll = SettingsPromptScrollView()
        scroll.borderType = .noBorder
        scroll.focusRingType = .none
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = Design.Radius.control
        scroll.layer?.masksToBounds = true
        scroll.layer?.borderWidth = 1
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let editor = SettingsPromptTextView(frame: scroll.contentView.bounds)
        editor.focusRingType = .none
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainerInset = NSSize(width: Design.Space.xs, height: Design.Space.xs)
        editor.font = Design.Settings.controlFont
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: SettingsPromptScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? SettingsPromptTextView else { return }
        scroll.applyTheme(theme)
        editor.isEditable = isEnabled
        editor.setAccessibilityLabel(accessibilityLabel)
        editor.placeholder = placeholder
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            let length = (text as NSString).length
            editor.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            editor.sizeToFit()
        }
        editor.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SettingsPromptEditor
        init(_ parent: SettingsPromptEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? SettingsPromptTextView else { return }
            if parent.text != editor.string { parent.text = editor.string }
            editor.needsDisplay = true
        }
    }
}

final class SettingsPromptScrollView: NSScrollView, ThemeApplying {
    private var palette = ThemePalette.system

    func applyTheme(_ palette: ThemePalette) {
        guard self.palette != palette || layer?.borderColor == nil else { return }
        self.palette = palette
        backgroundColor = palette.surfaceInset
        (documentView as? SettingsPromptTextView)?.applyTheme(palette)
        updateBorderColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    func updateBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = palette.separator.cgColor
        }
    }
}

final class SettingsPromptTextView: NSTextView {
    private var palette = ThemePalette.system

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        if !hasMarkedText() { textColor = palette.isSystem ? ThemePalette.nativeTextInk : palette.ink }
        backgroundColor = palette.surfaceInset
        applyThemeSelection(palette)
        needsDisplay = true
    }

    var placeholder = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = textContainerOrigin
        let rect = NSRect(x: origin.x + padding, y: origin.y,
                          width: max(0, bounds.width - origin.x * 2 - padding * 2),
                          height: max(0, bounds.height - origin.y * 2))
        (placeholder as NSString).draw(in: rect, withAttributes: [
            .font: font ?? Design.Settings.controlFont,
            .foregroundColor: palette.placeholder
        ])
    }
}
