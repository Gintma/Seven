import AppKit
import SwiftUI

indirect enum SettingsServiceMenuItem<Value: Hashable> {
    case option(Value, String)
    case separator
    case action(String, enabled: Bool, () -> Void)
    case submenu(String, [SettingsServiceMenuItem<Value>])
}

/// Reuses the grouped Form native menu environment from translation settings while letting the service detail view handle outer alignment.
struct SettingsServiceMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let items: [SettingsServiceMenuItem<Value>]
    var placeholder = ""
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    init(title: String, selection: Binding<Value>, options: [(Value, String)]) {
        self.title = title; self._selection = selection
        self.items = options.map { .option($0.0, $0.1) }
    }
    init(title: String, selection: Binding<Value>, items: [SettingsServiceMenuItem<Value>], placeholder: String = "") {
        self.title = title; self._selection = selection; self.items = items; self.placeholder = placeholder
    }

    var body: some View {
        SettingsMenuFormHost(content: Form {
            SettingsServiceMenuControl(title: title, selection: selection, items: items, placeholder: placeholder, isEnabled: isEnabled) {
                if selection != $0 { selection = $0 }
            }.fixedSize()
        }.settingsForm().groupBoxStyle(SettingsMenuFormGroupStyle()).scrollDisabled(true).scrollIndicators(.hidden).fixedSize()
            .environment(\.theme, theme)
            .environment(\.isEnabled, isEnabled).environment(\.colorScheme, colorScheme))
            .fixedSize()
    }
}

/// Exposes only the native button's layout bounds so the local Form's card chrome and margins do not consume space in the service row.
private struct SettingsMenuFormHost<Content: View>: NSViewRepresentable {
    let content: Content
    func makeNSView(context: Context) -> SettingsMenuFormViewport<Content> {
        SettingsMenuFormViewport(rootView: content)
    }
    func updateNSView(_ view: SettingsMenuFormViewport<Content>, context: Context) {
        view.host.rootView = content
        view.measureMenu()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SettingsMenuFormViewport<Content>, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

private final class SettingsMenuFormViewport<Content: View>: NSView {
    let host: NSHostingView<Content>
    private var menuSize = NSSize.zero
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { menuSize }

    init(rootView: Content) {
        host = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        host.sizingOptions = []
        identifier = NSUserInterfaceItemIdentifier("settingsMenuFormViewport")
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(host)
        measureMenu()
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(convert(point, from: superview)) else { return nil }
        // The clipping host shifts the bounds origin; forward clicks directly to the visible native button,
        // preventing the inner Form's scroll or hosting container from swallowing events in unclipped coordinates.
        return Self.menu(in: host)
    }

    override func layout() {
        super.layout()
        alignMenu()
    }

    func measureMenu() {
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        alignMenu()
    }

    private func alignMenu() {
        guard let menu = Self.menu(in: host) else { return }
        let rect = menu.convert(menu.bounds, to: host)
        setBoundsOrigin(rect.origin)
        if menuSize != rect.size {
            menuSize = rect.size
            invalidateIntrinsicContentSize()
        }
    }

    private static func menu(in view: NSView) -> NSPopUpButton? {
        if let menu = view as? NSPopUpButton { return menu }
        return view.subviews.lazy.compactMap { menu(in: $0) }.first
    }
}

private struct SettingsServiceMenuControl<Value: Hashable>: NSViewRepresentable {
    @Environment(\.theme) private var theme
    let title: String
    let selection: Value
    let items: [SettingsServiceMenuItem<Value>]
    let placeholder: String
    let isEnabled: Bool
    let onSelect: (Value) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton()
        button.controlSize = .regular
        button.font = Design.Text.settingsRow.nsFont
        button.isBordered = true
        (button.cell as? NSPopUpButtonCell)?.usesItemFromMenu = false
        (button.cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.chooseFromButton(_:))
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(title)
        var selectedItem: NSMenuItem?
        func makeMenu(_ entries: [SettingsServiceMenuItem<Value>], path: [String] = []) -> NSMenu {
          let menu = NSMenu()
          menu.autoenablesItems = false
          for entry in entries {
            switch entry {
            case .separator: menu.addItem(.separator())
            case .option(let value, let label):
                let item = NSMenuItem(title: label, action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
                item.target = context.coordinator
                item.representedObject = SettingsServiceMenuValue(value)
                item.state = value == selection ? .on : .off
                item.isEnabled = isEnabled
                if value == selection { selectedItem = item }
                menu.addItem(item)
            case .action(let label, let enabled, _):
                let item = NSMenuItem(title: label, action: #selector(Coordinator.runAction(_:)), keyEquivalent: "")
                item.target = context.coordinator
                item.representedObject = SettingsServiceMenuAction(path: path + [label])
                item.isEnabled = isEnabled && enabled
                menu.addItem(item)
            case .submenu(let label, let children):
                let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                item.submenu = makeMenu(children, path: path + [label])
                item.isEnabled = isEnabled
                menu.addItem(item)
            }
          }
          return menu
        }
        let menu = makeMenu(items)
        button.menu = menu
        if let selectedItem { button.select(selectedItem) } else { button.selectItem(at: -1) }
        button.applyThemeToMenuTitle(theme, title: selectedItem?.title ?? placeholder)
    }
    final class Coordinator: NSObject {
        var parent: SettingsServiceMenuControl
        init(_ parent: SettingsServiceMenuControl) { self.parent = parent }
        @objc func choose(_ item: NSMenuItem) {
            guard parent.isEnabled, let value = item.representedObject as? SettingsServiceMenuValue<Value>,
                  parent.items.contains(where: {
                      if case .option(let candidate, _) = $0 { return candidate == value.value }; return false
                  }) else { return }
            parent.onSelect(value.value)
        }
        @objc func runAction(_ item: NSMenuItem) {
            guard parent.isEnabled, item.isEnabled,
                  let route = item.representedObject as? SettingsServiceMenuAction else { return }
            // An already-open menu may still hold a pre-refresh item; invoke the current closure according to the current enabled state.
            func run(_ entries: [SettingsServiceMenuItem<Value>], path: ArraySlice<String>) {
                guard let head = path.first else { return }
                for entry in entries {
                    switch entry {
                    case .action(let label, let enabled, let action) where path.count == 1 && label == head:
                        if enabled { action() }
                        return
                    case .submenu(let label, let children) where label == head:
                        run(children, path: path.dropFirst())
                        return
                    default: break
                    }
                }
            }
            run(parent.items, path: route.path[...])
        }
        @objc func chooseFromButton(_ button: NSPopUpButton) {
            if let item = button.selectedItem { choose(item) }
        }
    }
}

private final class SettingsServiceMenuAction: NSObject {
    let path: [String]
    init(path: [String]) { self.path = path }
}

private final class SettingsServiceMenuValue<Value>: NSObject {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private struct SettingsMenuFormGroupStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.content }
}
