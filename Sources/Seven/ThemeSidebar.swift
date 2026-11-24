import AppKit
import SwiftUI

extension View {
    func themeSidebarRow(selected: Bool) -> some View {
        modifier(ThemeSidebarRow(selected: selected))
    }

    func themeSidebar(sourceListOnly: Bool = true) -> some View {
        modifier(ThemeSidebar(sourceListOnly: sourceListOnly))
    }
}

private struct ThemeSidebarRow: ViewModifier {
    @Environment(\.theme) private var theme
    let selected: Bool

    func body(content: Content) -> some View {
        content.listRowBackground(
            !theme.isSystem && selected
                ? RoundedRectangle(cornerRadius: Design.Radius.control)
                    .fill(theme.swiftUI.sidebarSelectionFill)
                    .padding(.horizontal, Design.Space.xs)
                : nil
        )
        .listItemTint(theme.isSystem ? nil : .fixed(theme.swiftUI.ink))
    }
}

private struct ThemeSidebar: ViewModifier {
    @Environment(\.theme) private var theme
    let sourceListOnly: Bool

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
            .background {
                ThemeSidebarConfiguration(theme: theme, sourceListOnly: sourceListOnly)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

/// 保留 List 及系统侧栏材质，用行背景表现选中状态。
private struct ThemeSidebarConfiguration: NSViewRepresentable {
    let theme: ThemePalette
    let sourceListOnly: Bool

    func makeNSView(context: Context) -> ConfigurationView { ConfigurationView() }

    func updateNSView(_ view: ConfigurationView, context: Context) {
        view.sourceListOnly = sourceListOnly
        view.applyTheme(theme)
    }

    final class ConfigurationView: NSView, ThemeApplying {
        private var usesSystemSelection = true
        var sourceListOnly = true
        private weak var table: NSTableView?
        private var previousStyle: NSTableView.SelectionHighlightStyle?

        func applyTheme(_ palette: ThemePalette) {
            usesSystemSelection = palette.isSystem
            updateSelection()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateSelection()
        }

        private func updateSelection() {
            applySelection()
            guard !usesSystemSelection, window != nil else { return }
            // SwiftUI 可能在同一帧稍后挂载或配置原生列表。
            DispatchQueue.main.async { [weak self] in self?.applySelection() }
        }

        private func applySelection() {
            guard !usesSystemSelection, let root = window?.contentView,
                  let current = findList(in: root) else {
                restoreSelection()
                return
            }
            if table !== current {
                restoreSelection()
                table = current
                previousStyle = current.selectionHighlightStyle
            }
            if current.selectionHighlightStyle != .none { current.selectionHighlightStyle = .none }
        }

        private func restoreSelection() {
            if let previousStyle { table?.selectionHighlightStyle = previousStyle }
            table = nil
            previousStyle = nil
        }

        private func findList(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, !sourceListOnly || table.style == .sourceList { return table }
            return view.subviews.lazy.compactMap { self.findList(in: $0) }.first
        }
    }
}
