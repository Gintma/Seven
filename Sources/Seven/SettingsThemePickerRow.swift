import AppKit
import SwiftUI

/// Light and dark appearances each pick from the same catalog, with swatches previewed in their respective variant.
struct SettingsThemePickerRow: View {
    let variant: ThemeVariant
    let manager: ThemeManager

    var body: some View {
        let title = variant == .light ? "浅色主题" : "深色主题"
        LabeledContent {
            SettingsThemeMenu(title: title, variant: variant, selection: manager.themeID(for: variant)) {
                manager.selectTheme($0, for: variant)
            }
            .id(variant)
            .fixedSize()
        } label: {
            Text(title).font(Design.Settings.rowFont)
        }
    }
}

private struct SettingsThemeMenu: NSViewRepresentable {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let variant: ThemeVariant
    let selection: String
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.font = Design.Text.settingsRow.nsFont
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))

        for preset in ThemePreset.choices(for: variant) {
            button.addItem(withTitle: preset.title)
            button.lastItem?.representedObject = preset.id
            button.lastItem?.image = swatchImage(preset.swatch(for: variant))
        }
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(title)
        let systemPalette = theme.isSystem && theme.variant == variant ? theme : ThemeResolver.system(variant)
        let systemItem = button.itemArray.first { ($0.representedObject as? String) == ThemePalette.systemID }
        systemItem?.image = swatchImage(systemPalette.swatch)
        button.select(selectedItem(in: button))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSPopUpButton, context: Context) -> CGSize? {
        guard let item = selectedItem(in: button) else { return nil }
        // AppKit sizes pop-up buttons to the widest menu item by default; measure the current selection with a single-item native cell.
        let cell = NSPopUpButtonCell(textCell: item.title, pullsDown: false)
        cell.controlSize = button.controlSize
        cell.font = button.font
        cell.selectedItem?.image = item.image
        return cell.cellSize
    }

    private func selectedItem(in button: NSPopUpButton) -> NSMenuItem? {
        button.itemArray.first { ($0.representedObject as? String) == selection } ?? button.itemArray.first
    }

    private func swatchImage(_ colors: ThemePalette.Swatch) -> NSImage {
        let size = NSSize(width: Design.Settings.themeSwatchWidth, height: Design.Settings.themeSwatchHeight)
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: Design.Radius.control, yRadius: Design.Radius.control)
            colors.surface.setFill()
            path.fill()
            colors.border.setStroke()
            path.stroke()
            let text = NSAttributedString(string: "Aa", attributes: [
                .font: Design.Text.note.nsFont, .foregroundColor: colors.accent
            ])
            let textSize = text.size()
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            return true
        }
    }

    final class Coordinator: NSObject {
        var onSelect: (String) -> Void

        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

        @objc func choose(_ button: NSPopUpButton) {
            guard let id = button.selectedItem?.representedObject as? String else { return }
            onSelect(id)
        }
    }
}
