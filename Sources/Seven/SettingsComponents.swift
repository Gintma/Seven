import SwiftUI
import AppKit

extension View {
    /// Own smart selection reads real layout bounds without participating in hit-testing or public accessibility navigation.
    func settingsSmartTarget(_ role: String) -> some View {
        background { SettingsSmartSelectionBoundary(role: role).allowsHitTesting(false).accessibilityHidden(true) }
    }
    func settingsOverlayScrollbars() -> some View {
        background { SettingsOverlayScrollConfiguration().frame(width: 0, height: 0) }
    }
    func settingsForm() -> some View {
        self.formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }
}

private struct SettingsSmartSelectionBoundary: NSViewRepresentable {
    let role: String
    func makeNSView(context: Context) -> SettingsSmartSelectionAnchor { SettingsSmartSelectionAnchor(role: role) }
    func updateNSView(_ view: SettingsSmartSelectionAnchor, context: Context) { view.smartRole = role }
}

final class SettingsSmartSelectionAnchor: NSView {
    var smartRole: String
    init(role: String) {
        smartRole = role; super.init(frame: .zero); setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Shared scrollable grouped container for settings panes; the About pane can display an app summary above the form.
struct SettingsForm<Header: View, Content: View>: View {
    let header: Header
    let content: Content
    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.header = header(); self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if #available(macOS 26, *) {
                form
                    .contentMargins(.top, Design.Settings.formTopMarginAdjustment, for: .scrollContent)
                    .scrollEdgeEffectStyle(.soft, for: .top)
            } else {
                form.clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var form: some View { Form { content }.settingsForm() }
}
extension SettingsForm where Header == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(header: { EmptyView() }, content: content)
    }
}

struct SettingsPageHeader: View {
    let title: String
    var body: some View {
        Text(title).font(Design.Text.sectionTitle.font)
            .foregroundStyle(ThemeStyle.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsDetailModeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var settingsDetailMode: Bool {
        get { self[SettingsDetailModeKey.self] }
        set { self[SettingsDetailModeKey.self] = newValue }
    }
}

struct SettingsGroup<Content: View, Footer: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.settingsDetailMode) private var detailMode
    let title: String?
    let description: String?
    let content: Content
    let footer: Footer
    init(_ title: String? = nil, description: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title; self.description = description; self.content = content(); self.footer = footer()
    }
    var body: some View {
        if detailMode {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                if let title { Text(title).font(Design.Settings.groupFont).foregroundStyle(ThemeStyle.ink) }
                if let description { SettingsNote(text: description, multiline: true) }
                VStack(alignment: .leading, spacing: Design.Space.l) { content }
                footer.font(Design.Text.note.font).foregroundStyle(ThemeStyle.inkSecondary)
            }
        } else {
            Section {
                descriptionRow.listRowBackground(theme.isSystem ? nil : theme.swiftUI.blockFill)
                content.listRowBackground(theme.isSystem ? nil : theme.swiftUI.blockFill)
            } header: {
                heading
            } footer: { styledFooter }
        }
    }

    @ViewBuilder private var descriptionRow: some View {
        if let description {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                if let title { Text(title).font(Design.Settings.groupFont).foregroundStyle(ThemeStyle.ink) }
                SettingsNote(text: description, multiline: true)
            }
        }
    }

    @ViewBuilder private var heading: some View {
        if description == nil, let title {
            Text(title).font(Design.Settings.groupFont).foregroundStyle(ThemeStyle.ink)
        }
    }

    private var styledFooter: some View {
        footer.font(Design.Text.note.font).foregroundStyle(ThemeStyle.inkSecondary)
    }
}
extension SettingsGroup where Footer == EmptyView {
    init(_ title: String? = nil, description: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.description = description; self.content = content(); self.footer = EmptyView()
    }
}

struct SettingsNote: View {
    let text: String
    var help: String? = nil
    var multiline = false
    var body: some View {
        Text(text).font(Design.Text.note.font).foregroundStyle(ThemeStyle.inkSecondary)
            .lineLimit(multiline ? nil : 1).help(help ?? text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Service detail uses full-width fields with the label above the control; grouped settings panes keep the standard row layout.
struct SettingsControlRow<Control: View>: View {
    let title: String
    let control: Control
    init(_ title: String, @ViewBuilder content: () -> Control) { self.title=title; self.control=content() }
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            if !title.isEmpty { Text(title).font(Design.Settings.rowFont) }
            control.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsInputRow: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    let title: String
    @Binding var text: String
    var placeholder = ""
    var explanation: String? = nil
    var onSubmit: () -> Void = {}
    var reset: (() -> Void)? = nil
    var defaultValue: String? = nil
    var onEndEditing: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            SettingsControlRow(title) {
                HStack(spacing: Design.Space.s) {
                    SettingsEditableTextField(text: $text, title: title, placeholder: placeholder,
                                              onSubmit: onSubmit, onEndEditing: onEndEditing)
                        .settingsSmartTarget("AXTextField")
                    if let reset, text != defaultValue {
                        Button(action: reset) { Image(systemName: "arrow.counterclockwise") }
                            .buttonStyle(.borderless).controlSize(.regular).font(Design.Settings.controlTextFont)
                            .frame(width: Design.Settings.controlHeight, height: Design.Settings.controlHeight)
                            .modifier(SettingsHoverStyle())
                            .help(L10n.text("restoreDefault")).accessibilityLabel(L10n.format("restoreDefaultFor", String(describing: title)))
                    }
                }
            }
            if let explanation { SettingsNote(text: explanation) }
        }
    }
}

struct SettingsKeyRow: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    let title: String
    @Binding var text: String
    @Binding var focused: Bool
    var isRevealed = false
    var reveal: () -> Void
    var onSubmit: () -> Void
    var body: some View {
        SettingsControlRow(title) {
            HStack(spacing: Design.Space.s) {
                SettingsEditableTextField(text: $text, title: title, placeholder: L10n.text("enterAPIKey"),
                                          style: .key(revealed: isRevealed), onSubmit: onSubmit,
                                          onEditingChange: { focused = $0 })
                    .id(isRevealed)
                Button(action: reveal) {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless).controlSize(.regular).font(Design.Settings.controlTextFont)
                .frame(width: Design.Settings.controlHeight, height: Design.Settings.controlHeight)
                .modifier(SettingsHoverStyle())
                .help(isRevealed ? L10n.text("hideAPIKey") : L10n.text("showAPIKey"))
                .accessibilityLabel(isRevealed ? L10n.text("hideAPIKey") : L10n.text("showAPIKey"))
            }
        }
    }
}

struct SettingsPickerRow<Value: Hashable, Choices: View>: View {
    @Environment(\.settingsDetailMode) private var detailMode
    let title: String
    @Binding var selection: Value
    let explanation: String?
    let titleNote: String?
    let choices: Choices
    init(_ title: String, selection: Binding<Value>, explanation: String? = nil, titleNote: String? = nil,
         @ViewBuilder content: () -> Choices) {
        self.title = title; self._selection = selection; self.choices = content()
        self.explanation = explanation; self.titleNote = titleNote
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            if detailMode {
                HStack(spacing: Design.Space.m) {
                    Text(title).font(Design.Settings.rowFont)
                    Spacer(minLength: Design.Space.s)
                    Picker(title, selection: $selection) { choices }.labelsHidden().pickerStyle(.menu)
                        .fixedSize().settingsSmartTarget("AXPopUpButton")
                }
            } else if let titleNote {
                HStack(alignment: .top, spacing: Design.Space.m) {
                    VStack(alignment: .leading, spacing: Design.Space.xs) {
                        Text(title)
                        SettingsNote(text: titleNote, multiline: true)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Picker(title, selection: $selection) { choices }
                        .labelsHidden().pickerStyle(.menu).fixedSize().settingsSmartTarget("AXPopUpButton")
                }
            } else {
                Picker(selection: $selection) { choices } label: { Text(title) }.pickerStyle(.menu)
            }
            if let explanation { SettingsNote(text: explanation) }
        }.settingsSmartTarget("AXRow")
    }
}

/// Service parameter menus size naturally to their content and align trailing, keeping the description in the same row group as the setting.
struct SettingsFixedPickerRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    var explanation: String? = nil
    let options: [(Value, String)]
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(spacing: Design.Space.m) {
                Text(title).font(Design.Settings.rowFont)
                Spacer(minLength: Design.Space.s)
                SettingsMenu(title: title, selection: $selection, options: options).fixedSize()
            }
            if let explanation { SettingsNote(text: explanation) }
        }
    }
}

/// Option for the custom-drawn segmented bridge; icons may combine with text while the name remains the native segment's AX title.
struct SettingsSegmentedOption<Value: Hashable> {
    let value: Value
    let title: String
    var image: NSImage? = nil
}

struct SettingsSegmentedControl<Value: Hashable>: View {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var selection: Value
    let options: [SettingsSegmentedOption<Value>]
    let accessibilityLabel: String

    var body: some View {
        SettingsSegmentedNativeControl(selection: selection, options: options,
            accessibilityLabel: accessibilityLabel, isEnabled: isEnabled,
            currentSelection: { selection }) { value in
                // Write only on user actions; do not use this frame's snapshot to skip writing back when rapid clicks return to the initial value.
                selection = value
            }
    }
}

/// Reads the selection snapshot inside SwiftUI body to avoid reading a stale previous-frame Binding value during native updates.
private struct SettingsSegmentedNativeControl<Value: Hashable>: NSViewRepresentable {
    @Environment(\.theme) private var theme
    let selection: Value
    let options: [SettingsSegmentedOption<Value>]
    let accessibilityLabel: String
    let isEnabled: Bool
    let currentSelection: () -> Value
    let onSelect: (Value) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SlidingSegmentedControl {
        let control = SlidingSegmentedControl(size: .compact)
        control.thumbInset = Design.Settings.segmentedThumbInset
        control.widthMode = .content
        control.trackingMode = .selectOne
        control.target = context.coordinator
        control.action = #selector(Coordinator.choose(_:))
        return control
    }
    func updateNSView(_ control: SlidingSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.applyTheme(theme)
        if control.segmentCount != options.count { control.segmentCount = options.count }
        for (index, option) in options.enumerated() {
            if control.label(forSegment: index) != option.title { control.setLabel(option.title, forSegment: index) }
            if control.image(forSegment: index) !== option.image { control.setImage(option.image, forSegment: index) }
        }
        control.isEnabled = isEnabled
        control.setAccessibilityLabel(accessibilityLabel)
        let index = options.firstIndex { $0.value == selection } ?? -1
        let values = options.map(\.value)
        let coordinator = context.coordinator
        func applyExternalSelection() {
            if coordinator.modelIndex != index || coordinator.optionValues != values || coordinator.wasEnabled != isEnabled {
                control.setSelectedSegment(index, animated: false)
            }
            coordinator.modelIndex = index
            coordinator.optionValues = values
            coordinator.wasEnabled = isEnabled
        }
        // Within a short window after a user action, any incoming frame may be older than the click: keep updating only options and geometry,
        // without modifying the native selection so an in-flight slide is not snapped to its end. Keep the window open even after a confirming frame arrives,
        // because older frames from the same refresh batch may still be queued after the confirming frame.
        if let accepted = coordinator.acceptedSelection {
            guard values.contains(accepted.value), ProcessInfo.processInfo.systemUptime < accepted.deadline else {
                coordinator.clearAcceptedSelection()
                applyExternalSelection()
                return
            }
            if let acceptedIndex = values.firstIndex(of: accepted.value), control.selectedSegment != acceptedIndex {
                // Re-layout only when geometry changes such as option reordering; leave animations untouched when the index is unchanged.
                control.setSelectedSegment(acceptedIndex, animated: false)
            }
            // Track the accepted value as the baseline rather than this frame's stale value so the selection does not drift to an old index when the window expires.
            coordinator.modelIndex = values.firstIndex(of: accepted.value) ?? index
            coordinator.optionValues = values
            coordinator.wasEnabled = isEnabled
            return
        }
        applyExternalSelection()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SlidingSegmentedControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
    static func dismantleNSView(_ control: SlidingSegmentedControl, coordinator: Coordinator) {
        coordinator.clearAcceptedSelection()
        control.target = nil
    }
    final class Coordinator: NSObject {
        struct AcceptedSelection {
            let value: Value
            let deadline: TimeInterval
        }
        // Short-window fallback: if the binding rejects a write, no confirming frame arrives; once expired, read the latest binding to resync.
        private static var settleWindow: TimeInterval { 0.25 }
        var parent: SettingsSegmentedNativeControl
        var modelIndex: Int?
        var optionValues: [Value] = []
        var wasEnabled: Bool?
        var acceptedSelection: AcceptedSelection?
        private var settleTimer: Timer?
        init(_ parent: SettingsSegmentedNativeControl) { self.parent = parent }
        @objc func choose(_ control: SlidingSegmentedControl) {
            let index = control.selectedSegment
            guard control.isEnabled, parent.options.indices.contains(index), control.isEnabled(forSegment: index) else { return }
            let value = parent.options[index].value
            accept(value, in: control)
            parent.onSelect(value)
        }
        /// Records the user's choice and holds the native selection during the window without delaying clicks, replaying actions, or writing the binding.
        private func accept(_ value: Value, in control: SlidingSegmentedControl) {
            clearAcceptedSelection()
            acceptedSelection = AcceptedSelection(value: value, deadline: ProcessInfo.processInfo.systemUptime + Self.settleWindow)
            let timer = Timer(timeInterval: Self.settleWindow, repeats: false) { [weak self, weak control] _ in
                MainActor.assumeIsolated {
                    guard let self, let control, self.acceptedSelection != nil else { return }
                    self.reconcileCurrentSelection(in: control)
                }
            }
            settleTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        func clearAcceptedSelection() {
            settleTimer?.invalidate(); settleTimer = nil
            acceptedSelection = nil
        }
        func reconcileCurrentSelection(in control: SlidingSegmentedControl) {
            clearAcceptedSelection()
            let value = parent.currentSelection()
            let index = parent.options.firstIndex { $0.value == value } ?? -1
            control.setSelectedSegment(index, animated: false)
            modelIndex = index
        }
    }
}

/// Shares the leading/trailing layout with fixed menu rows; segments size to content instead of filling remaining space.
struct SettingsSegmentedRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    var explanation: String? = nil
    let options: [(Value, String)]
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(spacing: Design.Space.m) {
                Text(title).font(Design.Settings.rowFont)
                Spacer(minLength: Design.Space.s)
                SettingsSegmentedControl(selection: $selection,
                    options: options.map { SettingsSegmentedOption(value: $0.0, title: $0.1) },
                    accessibilityLabel: title).fixedSize()
            }
            if let explanation { SettingsNote(text: explanation) }
        }.settingsSmartTarget("AXRow")
    }
}

/// System Settings-style toggle row: label leading, toggle trailing, and description as inline secondary text.
struct SettingsToggleRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.settingsDetailMode) private var detailMode
    let title: String
    @Binding var isOn: Bool
    var explanation: String? = nil
    init(_ title: String, isOn: Binding<Bool>, explanation: String? = nil) {
        self.title=title; self._isOn=isOn; self.explanation=explanation
    }
    var body: some View {
        if detailMode {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    Text(title).font(Design.Settings.rowFont)
                    if let explanation {
                        Text(explanation).font(Design.Text.note.font).foregroundStyle(ThemeStyle.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.toggleStyle(.switch).tint(theme.isSystem ? nil : theme.swiftUI.switchFill).controlSize(.mini).settingsSmartTarget("AXCheckBox")
        } else {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                Toggle(isOn: $isOn) { Text(title).font(Design.Settings.rowFont) }
                .toggleStyle(.switch).tint(theme.isSystem ? nil : theme.swiftUI.switchFill)
                .controlSize(.mini).settingsSmartTarget("AXCheckBox")
                if let explanation { Text(explanation).font(Design.Text.note.font).foregroundStyle(ThemeStyle.inkSecondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

/// Native language pop-up button supporting submenus while preserving the full current language name on the button.
struct SettingsLanguagePickerRow: View {
    let title: String
    @ObservedObject var model: TranslationModel
    @Binding var selection: String
    var body: some View {
        LabeledContent(title) {
            SettingsLanguageMenu(common: model.commonLanguages, other: model.otherLanguages, selection: $selection)
                .fixedSize()
                .accessibilityLabel(title)
        }
    }
}

struct SettingsLanguageMenu: NSViewRepresentable {
    @Environment(\.theme) private var theme
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    let common: [String]
    let other: [String]
    @Binding var selection: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton()
        button.controlSize = .regular
        button.font = Design.Text.settingsRow.nsFont
        button.isBordered = true
        (button.cell as? NSPopUpButtonCell)?.usesItemFromMenu = false
        (button.cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ code: String) -> NSMenuItem {
            let item = NSMenuItem(title: LanguageCatalog.name(code), action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
            item.target = context.coordinator
            item.representedObject = code
            item.state = code == selection ? .on : .off
            return item
        }
        for code in common { menu.addItem(item(code)) }
        let more = NSMenuItem(title: L10n.text("moreLanguages"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for code in other { submenu.addItem(item(code)) }
        more.submenu = submenu
        menu.addItem(more)
        button.menu = menu
        button.applyThemeToMenuTitle(theme, title: LanguageCatalog.name(selection))
    }
    final class Coordinator: NSObject {
        var parent: SettingsLanguageMenu
        init(_ parent: SettingsLanguageMenu) { self.parent = parent }
        @objc func choose(_ sender: NSMenuItem) {
            guard let code = sender.representedObject as? String else { return }
            parent.selection = code
        }
    }
}

struct SettingsCommonLanguages: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    @ObservedObject var model: TranslationModel
    @State private var selection: String?
    @State private var addingLanguages = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsNote(text: L10n.text("shownFirstInLanguageMenusDragTo"))
                .padding(.horizontal, Design.Settings.commonLanguageCardInset)
                .frame(height: Design.Settings.commonLanguageDescriptionHeight)
            ThemedDivider()
            SettingsSecondaryList(items: model.commonLanguages.map { SettingsSecondaryItem(id: $0, title: LanguageCatalog.name($0)) },
                                  selection: $selection, move: model.moveCommonLanguage, allowsEmptySelection: true, compactLanguages: true)
                .frame(height: CGFloat(model.commonLanguages.count) * Design.Settings.commonLanguageRowHeight)
                .accessibilityLabel(L10n.text("favoriteLanguagesDragToReorder"))
            ThemedDivider()
            HStack(spacing: Design.Space.m) {
                Button { addingLanguages = true } label: { Image(systemName: "plus") }
                    .modifier(SettingsHoverStyle())
                    .disabled(model.otherLanguages.isEmpty)
                    .accessibilityLabel(L10n.text("addFavoriteLanguages"))
                ThemedDivider(axis: .vertical).frame(height: Design.Icon.small)
                Button {
                    if let code = selection {
                        model.setCommonLanguage(code, isCommon: false)
                        selection = nil
                    }
                } label: { Image(systemName: "minus") }
                    .modifier(SettingsHoverStyle())
                    .disabled(model.commonLanguages.count <= 1 || selection == nil)
                    .accessibilityLabel(L10n.text("removeSelectedLanguage"))
                Spacer()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, Design.Settings.commonLanguageCardInset)
            .frame(height: Design.Settings.commonLanguageActionsHeight)
        }
        .padding(-Design.Settings.commonLanguageCardInset)
        .sheet(isPresented: $addingLanguages) {
            SettingsLanguageAddition(availableCodes: model.otherLanguages) { codes in
                for code in codes { model.setCommonLanguage(code, isCommon: true) }
                selection = codes.last
            }
        }
    }
}

/// Display and search data for the Add Language sheet; ordering always comes from the existing language catalog.
struct SettingsLanguageChoice: Identifiable {
    let id: String
    let nativeName: String
    let title: String
    let englishName: String
    init(code: String) {
        id = code
        title = LanguageCatalog.name(code)
        nativeName = Self.nativeName(for: code) ?? title
        englishName = Locale(identifier: "en").localizedString(forIdentifier: code) ?? ""
    }
    static func nativeName(for code: String) -> String? {
        guard let name = Locale(identifier: code).localizedString(forIdentifier: code), let first = name.first else { return nil }
        return String(first).capitalized(with: Locale(identifier: code)) + name.dropFirst()
    }
    static func displayNativeName(_ name: String, code: String) -> String {
        Locale.Language(identifier: code).characterDirection == .rightToLeft ? "\u{2068}" + name + "\u{2069}" : name
    }
    static var leftToRightParagraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = .leftToRight
        style.alignment = .left
        return style
    }
    func rowText(theme: ThemePalette = .system) -> NSAttributedString {
        let text = NSMutableAttributedString(string: Self.displayNativeName(nativeName, code: id), attributes: [.font: Design.Text.settingsRow.nsFont, .foregroundColor: theme.ink])
        text.append(NSAttributedString(string: "\u{2002}—\u{2002}" + title, attributes: [.font: Design.Text.settingsRow.nsFont, .foregroundColor: theme.inkSecondary]))
        text.addAttribute(.paragraphStyle, value: Self.leftToRightParagraph, range: NSRange(location: 0, length: text.length))
        return text
    }
    static func filtered(codes: [String], query: String) -> [Self] {
        codes.map(Self.init).filter { choice in
            query.isEmpty || [choice.id, choice.nativeName, choice.title, choice.englishName].contains {
                $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
    static func selectedCodes(in choices: [Self], selection: Set<String>) -> [String] {
        choices.map(\.id).filter(selection.contains)
    }
}

struct SettingsLanguageAddition: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    @Environment(\.dismiss) private var dismiss
    let availableCodes: [String]
    let add: ([String]) -> Void
    @State private var query = ""
    @State private var selection: Set<String> = []
    private var choices: [SettingsLanguageChoice] { SettingsLanguageChoice.filtered(codes: availableCodes, query: query) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("chooseLanguagesToAddToFavorites")).font(Design.Settings.groupFont)
                Spacer()
                SettingsLanguageSearch(text: $query)
                    .frame(width: Design.Settings.languageSearchWidth)
            }
            .frame(height: Design.Settings.controlHeight)
            .padding(.bottom, Design.Settings.languageAdditionHeaderSpacing)
            ZStack {
                SettingsLanguageAdditionList(choices: choices, selection: $selection) { code in
                    add([code]); dismiss()
                }
                if choices.isEmpty {
                    Text(L10n.text("noMatchingLanguages"))
                        .font(Design.Settings.rowFont)
                        .foregroundStyle(ThemeStyle.inkSecondary)
                }
            }
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Text(L10n.text("cancel")).frame(minWidth: Design.Settings.languageAdditionButtonLabelWidth)
                }.keyboardShortcut(.cancelAction)
                Button {
                    add(SettingsLanguageChoice.selectedCodes(in: choices, selection: selection)); dismiss()
                } label: {
                    Text(L10n.text("add")).frame(minWidth: Design.Settings.languageAdditionButtonLabelWidth)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(SettingsLanguageChoice.selectedCodes(in: choices, selection: selection).isEmpty)
            }
            .buttonStyle(.bordered)
            .padding(.top, Design.Settings.languageAdditionActionsSpacing)
        }
        .padding(.horizontal, Design.Settings.languageAdditionInset)
        .padding(.top, Design.Settings.languageAdditionInset)
        .padding(.bottom, Design.Settings.languageAdditionActionsSpacing)
        .frame(width: Design.Settings.languageAdditionWidth, height: Design.Settings.languageAdditionHeight)
    }
}

/// Uses the system search field's magnifying glass and clear button.
struct SettingsLanguageSearch: NSViewRepresentable {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = SearchField()
        field.focusRingType = .none
        field.placeholderString = L10n.text("search")
        field.setAccessibilityLabel(L10n.text("searchLanguages"))
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        field.isEnabled = isEnabled
        field.applyTheme(theme, placeholder: L10n.text("search"))
        field.setAccessibilityLabel(L10n.text("searchLanguages"))
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
    private final class SearchField: NSSearchField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            requestFocusAfterAttachingToWindow()
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SettingsLanguageSearch
        init(_ parent: SettingsLanguageSearch) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
    }
}

/// Native multi-select list preserving ⌘/⇧ selection and double-click behavior.
struct SettingsLanguageAdditionList: NSViewRepresentable {
    @Environment(\.theme) private var theme
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    let choices: [SettingsLanguageChoice]
    @Binding var selection: Set<String>
    let doubleClick: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language")))
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.autoresizingMask = [.width]
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.rowHeight = Design.Settings.commonLanguageRowHeight
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.addClickedLanguage(_:))
        table.setAccessibilityLabel(L10n.text("languagesYouCanAddMultipleSelectionIs"))
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        OverlayScrollerPolicy.configure(scroll)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        table.setAccessibilityLabel(L10n.text("languagesYouCanAddMultipleSelectionIs"))
        let previous = coordinator.parent.choices
        let changed = coordinator.palette != theme || previous.count != choices.count || zip(previous, choices).contains {
            $0.id != $1.id || $0.title != $1.title
        }
        coordinator.parent = self
        coordinator.updating = true
        coordinator.applyTheme(theme)
        table.backgroundColor = theme.surfaceRaised
        scroll.backgroundColor = table.backgroundColor
        defer { coordinator.updating = false }
        if changed || table.numberOfRows != choices.count { table.reloadData() }
        table.tableColumns.first?.width = scroll.contentSize.width
        table.selectRowIndexes(IndexSet(choices.indices.filter { selection.contains(choices[$0].id) }), byExtendingSelection: false)
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, ThemeApplying {
        private(set) var palette = ThemePalette.system
        func applyTheme(_ palette: ThemePalette) { self.palette = palette }

        var parent: SettingsLanguageAdditionList
        var updating = false
        init(_ parent: SettingsLanguageAdditionList) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.choices.count }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            palette.isSystem ? nil : ThemedTableRow(palette: palette)
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let choice = parent.choices[row]
            let label = NSTextField(labelWithAttributedString: choice.rowText(theme: palette))
            label.alignment = .left
            label.lineBreakMode = .byTruncatingTail
            let cell = NSTableCellView()
            cell.addSubview(label); cell.textField = label
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Design.Settings.languageAdditionRowInset),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Design.Settings.languageAdditionRowInset),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            parent.selection = Set(table.selectedRowIndexes.map { parent.choices[$0].id })
        }
        @objc func addClickedLanguage(_ table: NSTableView) {
            guard parent.choices.indices.contains(table.clickedRow) else { return }
            parent.doubleClick(parent.choices[table.clickedRow].id)
        }
    }
}

struct SettingsButtonRow<Actions: View>: View {
    let title: String
    let explanation: String?
    let actions: Actions

    init(_ title: String, explanation: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.explanation = explanation
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            LabeledContent {
                actions.buttonStyle(.bordered).settingsSmartTarget("AXButton")
            } label: {
                Text(title).font(Design.Settings.rowFont)
            }
            if let explanation {
                SettingsNote(text: explanation, multiline: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Keeps download status and its corresponding action on the same row while allowing long status text to wrap.
struct SettingsStatusActionRow<Actions: View>: View {
    let title: String
    let message: String
    let isError: Bool
    let isLoading: Bool
    let actions: Actions
    init(title: String, status: String, isError: Bool = false, isLoading loading: Bool = false, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.message = status; self.isError = isError; isLoading = loading; self.actions = actions()
    }
    var body: some View {
        SettingsControlRow(title) {
            HStack(alignment: .center, spacing: Design.Space.m) {
                if isLoading { ProgressView().controlSize(.small) }
                Group {
                    if isError { SettingsStatus(text: message, isError: true) }
                    else { Text(message).font(Design.Text.note.font).foregroundStyle(ThemeStyle.inkSecondary) }
                }
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Design.Space.s)
                actions.buttonStyle(.bordered).settingsSmartTarget("AXButton")
            }
        }
    }
}

struct SettingsValueRow: View {
    @Environment(\.settingsDetailMode) private var detailMode
    let title: String
    let value: String
    var body: some View {
        if detailMode {
            HStack(spacing: Design.Space.m) {
                Text(title).font(Design.Settings.rowFont)
                Spacer(minLength: Design.Space.s)
                Text(value).foregroundStyle(ThemeStyle.inkSecondary)
            }.font(Design.Settings.rowFont)
        } else {
            LabeledContent { Text(value) } label: { Text(title).font(Design.Settings.rowFont) }
        }
    }
}

struct SettingsTextRow: View {
    let title: String
    @Binding var text: String
    var placeholder = ""
    var explanation: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            SettingsControlRow(title) {
                SettingsPromptEditor(text: $text, placeholder: placeholder, accessibilityLabel: title)
                    .frame(height: Design.Settings.promptEditorHeight)
                    .settingsSmartTarget("AXTextArea")
            }
            if let explanation {
                SettingsNote(text: explanation, multiline: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Read-only long content expands on demand, showing only a summary by default so it does not take over the whole pane.
struct SettingsExpandableTextRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    let summary: String
    let text: String
    let accessibilityLabel: String
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(spacing: Design.Space.m) {
                Text(summary).font(Design.Settings.rowFont).foregroundStyle(ThemeStyle.ink)
                Spacer(minLength: Design.Space.s)
                Button { expanded.toggle() } label: {
                    SettingsLinkLabel(title: L10n.text(expanded ? "collapse" : "show"))
                }
                .buttonStyle(.link)
                .tint(theme.isSystem ? nil : theme.swiftUI.link)
                .modifier(SettingsHoverStyle())
                .accessibilityLabel(L10n.format(expanded ? "collapseDetails" : "showDetails", accessibilityLabel))
            }
            if expanded {
                Text(text).font(Design.Text.note.font).foregroundStyle(ThemeStyle.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}

struct SettingsPromptVariables: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    private var variables: [(String, String)] { [
        ("{{target}}", L10n.text("targetLanguageSelectedInTheWindow")),
        ("{{firstLanguage}}", L10n.text("firstLanguageInSettings")),
        ("{{text}}", L10n.text("service.prompt.originalText"))
    ] }
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text(L10n.text("service.prompt.insertableVariables"))
            Grid(alignment: .leading, horizontalSpacing: Design.Space.l, verticalSpacing: Design.Space.xs) {
                ForEach(variables, id: \.0) { token, meaning in
                    GridRow {
                        Text(token).font(Design.Text.note.font.monospaced())
                        Text(meaning)
                    }
                }
            }
        }
        .font(Design.Text.note.font).foregroundStyle(ThemeStyle.inkSecondary)
        .textSelection(.enabled)
    }
}

struct SettingsFooter<Status: View>: View {
    let buttonTitle: String
    var disabled=false
    let action: () -> Void
    let statusContent: Status
    init(_ buttonTitle: String, disabled: Bool = false, action: @escaping () -> Void,
         @ViewBuilder status: () -> Status) {
        self.buttonTitle=buttonTitle; self.disabled=disabled; self.action=action
        self.statusContent=status()
    }
    var body: some View {
        // An empty Section uses only the footer slot without creating a separate group card.
        Section { EmptyView() } footer: {
            VStack(alignment: .leading, spacing: Design.Space.s) {
                HStack(spacing: Design.Space.m) {
                    Spacer(minLength: Design.Space.s)
                    statusContent.font(Design.Text.note.font)
                    Button(buttonTitle, action: action).buttonStyle(.bordered).disabled(disabled).settingsSmartTarget("AXButton")
                }
            }
        }
    }
}

struct SettingsPrivacyNote: View {
    let text: String
    let detail: String
    var body: some View {
        SettingsNote(text: text, help: detail).accessibilityLabel(detail)
    }
}

struct SettingsSliderRow: View {
    @Environment(\.theme) private var theme
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueLabel: String
    var body: some View {
        LabeledContent {
            HStack(spacing: Design.Space.m) {
                Slider(value: $value, in: range)
                    .tint(theme.isSystem ? nil : theme.swiftUI.accentFill)
                    .frame(width: Design.Settings.sliderWidth)
                Text(valueLabel).monospacedDigit().frame(width: Design.Settings.valueWidth, alignment: .trailing)
            }
        } label: { Text(title).font(Design.Settings.rowFont) }
    }
}

struct SettingsLinearProgress: View {
    @Environment(\.theme) private var theme
    let value: Double

    var body: some View {
        ProgressView(value: value)
            .progressViewStyle(.linear)
            .tint(theme.isSystem ? nil : theme.swiftUI.accentFill)
    }
}

private struct SettingsInlineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
            configuration.icon
            configuration.title
        }
    }
}

struct SettingsStatus: View {
    let text: String
    var isError = false
    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.circle" : "checkmark")
            .labelStyle(SettingsInlineLabelStyle())
            .font(Design.Text.note.font)
            .foregroundStyle(isError ? ThemeStyle.error : ThemeStyle.accentInk)
            .fixedSize(horizontal: false, vertical: true).help(text)
    }
}

struct SettingsPermissionRow: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    let title: String
    let granted: Bool
    let authorize: () -> Void
    var body: some View {
        HStack {
            Label {
                Text(granted ? L10n.format("granted", String(describing: title)) : L10n.format("notGranted", String(describing: title))).font(Design.Settings.rowFont)
                    .foregroundStyle(granted ? ThemeStyle.accentInk : ThemeStyle.ink)
            } icon: {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .foregroundStyle(granted ? ThemeStyle.accentInk : ThemeStyle.warning)
                    .accessibilityLabel(granted ? L10n.text("granted2") : L10n.text("warning"))
            }
            .labelStyle(SettingsInlineLabelStyle())
            Spacer()
            if !granted { Button(L10n.text("grantAccess"), action: authorize).buttonStyle(.bordered) }
        }
    }
}

/// Unset shortcuts use a system button; editable keycaps are clickable, while fixed keycaps are rendered directly by the caller.
struct SettingsShortcutButton:View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    let keys:[String]
    let title:String
    let record:()->Void
    var body:some View {
        Group {
            if keys.isEmpty {Button(L10n.text("set"),action:record).buttonStyle(.bordered)}
            else {Button(action:record){KeycapRow(keys:keys)}.buttonStyle(.borderless).modifier(SettingsHoverStyle())}
        }.help(L10n.format("clickToRecordANewShortcutFor", String(describing: title)))
            .accessibilityLabel(L10n.format("shortcutForClickToRecord", String(describing: title), String(describing: keys.isEmpty ? L10n.text("notSet"):keys.joined())))
    }
}

struct SettingsShortcutRow: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    let title: String
    @ObservedObject var manager: HotKeyManager
    let allManagers: [HotKeyManager]
    @Binding var isRecording: Bool
    var explanation: String? = nil
    var explanationHelp: String? = nil
    var body: some View {
        HStack(alignment: .center, spacing: Design.Space.m) {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                Text(title).font(Design.Settings.rowFont)
                if let explanation { SettingsNote(text: explanation, help: explanationHelp) }
                if let problem = manager.problem {
                    SettingsStatus(text: problem, isError: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            SettingsShortcutButton(keys: manager.isEnabled ? manager.shortcut.keyLabels : [], title: title) {
                isRecording = true
            }
            .fixedSize()
            .popover(isPresented: $isRecording, arrowEdge: .bottom) {
                ShortcutCaptureView(action: title, manager: manager, allManagers: allManagers)
            }
        }
    }
}

/// A single keycap used in settings row shortcut buttons and the recording popover. Scales with the active font size tier.
struct Keycap: View {
    @Environment(\.theme) private var theme
    enum Style { case normal, placeholder, accent, empty, fixed }

    let label: String
    var style: Style = .normal
    var text: Design.Text = .label

    var body: some View {
        Text(style == .empty ? " " : label)
            .font(text.font)
            .foregroundStyle(style == .accent ? ThemeStyle.accentInk : ThemeStyle.nativePrimary)
            .padding(.horizontal, Design.Space.xs + Design.Space.xxs)
            .frame(minWidth: text.size * 2, minHeight: text.size * 2)
            .background {
                RoundedRectangle(cornerRadius: Design.Keycap.radius, style: .continuous)
                    .fill(style == .empty ? ThemePalette.transparent : (style == .fixed ? theme.swiftUI.keycapFixedFill : theme.swiftUI.keycapFill))
                    .shadow(color: hasShadow ? theme.swiftUI.keycapShadow : ThemePalette.transparent, radius: 0.5, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Design.Keycap.radius, style: .continuous)
                    .strokeBorder(border, style: StrokeStyle(
                        lineWidth: Design.Keycap.strokeWidth, dash: style == .empty ? [3, 2] : []
                    ))
            }
            .opacity(style == .placeholder ? Design.Opacity.disabled : 1)
    }

    private var hasShadow: Bool { style == .normal || style == .accent }

    private var border: Color {
        switch style {
        case .accent: return theme.swiftUI.keycapSuccessStroke
        case .fixed:return ThemePalette.transparent
        case .empty: return theme.swiftUI.keycapEmptyStroke
        case .normal, .placeholder: return theme.swiftUI.keycapStroke
        }
    }
}

struct KeycapRow: View {
    let keys: [String]
    var style: Keycap.Style = .normal
    var text: Design.Text = .label

    var body: some View {
        HStack(spacing: Design.Keycap.spacing) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Keycap(label: key, style: style, text: text)
            }
        }
    }
}


/// Secondary list using an AppKit table view with unfocused selection styling.
struct SettingsSecondaryItem {
    let id: String
    let title: String
    var image: NSImage? = nil
    var enabled: Bool? = nil
    var allowsToggle = true
    var isGroup = false
    var accessibilityStatus: String? = nil
}

struct SettingsSecondaryList: NSViewRepresentable {
    @Environment(\.theme) private var theme
    let items: [SettingsSecondaryItem]
    @Binding var selection: String?
    var toggle: ((String, Bool) -> Void)? = nil
    var move: ((IndexSet, Int) -> Void)? = nil
    var allowsEmptySelection = false
    var compactLanguages = false
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView(); table.style = compactLanguages ? .plain : .inset
        table.allowsEmptySelection = allowsEmptySelection
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("service"))
        table.addTableColumn(column); table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        table.intercellSpacing = NSSize(width: 0, height: compactLanguages ? 0 : Design.Space.xxs)
        table.selectionHighlightStyle = .regular
        table.backgroundColor = ThemePalette.clear
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.registerForDraggedTypes([Coordinator.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true
        if compactLanguages { scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
        scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.scrollerStyle = .overlay
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        if compactLanguages { table.tableColumns.first?.width = scroll.contentSize.width }
        let coordinator = context.coordinator
        let old = coordinator.parent.items
        let changed = coordinator.palette != theme || !coordinator.hasLoaded || old.count != items.count || zip(old, items).contains {
            $0.id != $1.id || $0.title != $1.title || $0.enabled != $1.enabled || $0.allowsToggle != $1.allowsToggle || $0.isGroup != $1.isGroup || $0.accessibilityStatus != $1.accessibilityStatus
        }
        coordinator.parent = self; coordinator.updating = true
        coordinator.applyTheme(theme)
        defer { coordinator.updating = false }
        if changed {
            let origin = scroll.contentView.bounds.origin
            table.reloadData(); coordinator.hasLoaded = true
            scroll.contentView.scroll(to: origin)
        }
        if let row = items.firstIndex(where: { !$0.isGroup && $0.id == selection }) {
            if table.selectedRow != row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        } else if table.selectedRow != -1 { table.deselectAll(nil) }
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, ThemeApplying {
        private(set) var palette = ThemePalette.system
        func applyTheme(_ palette: ThemePalette) { self.palette = palette }
        static let dragType = NSPasteboard.PasteboardType("com.crissun.seven.settings-service")
        var parent: SettingsSecondaryList
        var updating = false
        var hasLoaded = false
        init(_ parent: SettingsSecondaryList) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.items.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            parent.compactLanguages ? Design.Settings.commonLanguageRowHeight : (parent.items[row].isGroup ? Design.Space.xl : Design.Settings.secondaryRowHeight)
        }
        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !parent.items[row].isGroup }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = NeutralRow(palette: palette)
            if parent.compactLanguages {
                view.languageRowFill = row.isMultiple(of: 2) ? palette.commonLanguageRowFill : palette.commonLanguageAlternateRowFill
            }
            return view
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = parent.items[row]
            let nativeName = parent.compactLanguages ? SettingsLanguageChoice.nativeName(for: item.id) : nil
            let label = NSTextField(labelWithString: nativeName ?? item.title)
            if parent.compactLanguages, let nativeName {
                label.attributedStringValue = NSAttributedString(string: SettingsLanguageChoice.displayNativeName(nativeName, code: item.id), attributes: [.paragraphStyle: SettingsLanguageChoice.leftToRightParagraph])
                label.alignment = .left
            }
            label.font = item.isGroup ? Design.Settings.groupNSFont : (parent.compactLanguages ? Design.Text.settingsRow.nsFont : Design.Text.body.nsFont)
            label.textColor = item.isGroup ? palette.inkSecondary : palette.ink
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityHelp(item.accessibilityStatus)
            let cell = NSTableCellView()
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label); cell.textField = label
            var leading = cell.leadingAnchor
            if let image = item.image {
                let icon = NSImageView(image: image); icon.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(icon); cell.imageView = icon
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: leading),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: Design.Icon.brand),
                    icon.heightAnchor.constraint(equalToConstant: Design.Icon.brand)
                ])
                leading = icon.trailingAnchor
            }
            var trailing = cell.trailingAnchor
            if parent.compactLanguages {
                let name = NSTextField(labelWithString: nativeName == nil ? "" : item.title)
                name.font = Design.Text.settingsRow.nsFont
                name.textColor = palette.inkSecondary
                name.translatesAutoresizingMaskIntoConstraints = false
                name.alignment = .left
                cell.addSubview(name)
                NSLayoutConstraint.activate([
                    name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    name.trailingAnchor.constraint(equalTo: cell.trailingAnchor)
                ])
                // Position the second column proportionally so every row's interface language name aligns at the same starting x-coordinate.
                NSLayoutConstraint(item: name, attribute: .leading, relatedBy: .equal,
                                   toItem: cell, attribute: .trailing,
                                   multiplier: Design.Settings.commonLanguageNativeColumnRatio, constant: Design.Settings.commonLanguageCardInset).isActive = true
                trailing = name.leadingAnchor
            }
            if let enabled = item.enabled {
                let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleService(_:)))
                button.translatesAutoresizingMaskIntoConstraints = false
                button.state = enabled ? .on : .off; button.controlSize = .small; button.tag = row
                button.isEnabled = item.allowsToggle
                button.setAccessibilityLabel(L10n.format("enable", String(describing: item.title)))
                button.setContentHuggingPriority(.required, for: .horizontal)
                button.setContentCompressionResistancePriority(.required, for: .horizontal)
                cell.addSubview(button)
                NSLayoutConstraint.activate([
                    button.trailingAnchor.constraint(equalTo: trailing),
                    button.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
                trailing = button.leadingAnchor
            }
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leading, constant: parent.compactLanguages ? Design.Settings.commonLanguageCardInset : (item.image == nil ? 0 : Design.Space.s)),
                label.trailingAnchor.constraint(equalTo: trailing, constant: item.enabled == nil ? 0 : -Design.Space.s),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        @objc private func toggleService(_ sender: NSButton) {
            guard parent.items.indices.contains(sender.tag) else { return }
            parent.toggle?(parent.items[sender.tag].id, sender.state == .on)
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            if table.selectedRow == -1, parent.allowsEmptySelection { parent.selection = nil; return }
            guard parent.items.indices.contains(table.selectedRow), !parent.items[table.selectedRow].isGroup else { return }
            parent.selection = parent.items[table.selectedRow].id
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.move != nil, !parent.items[row].isGroup else { return nil }
            let item = NSPasteboardItem(); item.setString(parent.items[row].id, forType: Self.dragType); return item
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard parent.move != nil, (info.draggingSource as? NSTableView) === tableView,
                  operation == .above, row >= 0 else { return [] }
            return .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard let move = parent.move, (info.draggingSource as? NSTableView) === tableView,
                  let id = info.draggingPasteboard.string(forType: Self.dragType),
                  let source = parent.items.firstIndex(where: { !$0.isGroup && $0.id == id }), row >= 0 else { return false }
            let sourceIndex = parent.items.prefix(source).filter { !$0.isGroup }.count
            let destination = parent.items.prefix(row).filter { !$0.isGroup }.count
            move(IndexSet(integer: sourceIndex), destination)
            return true
        }
    }
    private final class NeutralRow: ThemedTableRow {
        var languageRowFill: NSColor?
        override func drawBackground(in dirtyRect: NSRect) {
            guard let languageRowFill else { super.drawBackground(in: dirtyRect); return }
            languageRowFill.setFill()
            dirtyRect.fill()
        }
        override var isEmphasized: Bool { get { false } set {} }
    }
}

/// Native light-gray joined plus/minus control: equal widths, momentary actions, and no persistent selection state.
struct SettingsListActions: NSViewRepresentable {
    @Environment(\.theme) private var theme
    var canRemove: Bool
    let add: () -> Void
    let remove: () -> Void
    var addTitle = L10n.text("addService")
    var removeTitle = L10n.text("deleteService")
    var additions: [(String, String)] = []
    var chooseAddition: ((String) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 2
        control.segmentStyle = .rounded
        control.trackingMode = .momentary
        control.controlSize = .regular
        for segment in 0..<2 { control.setWidth(Design.Settings.listActionSize, forSegment: segment) }
        control.target = context.coordinator; control.action = #selector(Coordinator.performAction(_:))
        control.setContentHuggingPriority(.required, for: .horizontal)
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        control.setToolTip(addTitle, forSegment: 0)
        control.setToolTip(removeTitle, forSegment: 1)
        let addInk = theme.isSystem ? nil : theme.ink
        let removeInk = theme.isSystem ? nil : (canRemove ? theme.ink : theme.disabledInk)
        control.setImage(Design.Icon.symbol("plus", description: addTitle, tint: addInk), forSegment: 0)
        control.setImage(Design.Icon.symbol("minus", description: removeTitle, tint: removeInk), forSegment: 1)
        context.coordinator.parent = self
        control.setEnabled(true, forSegment: 0)
        control.setEnabled(canRemove, forSegment: 1)
        let menu = NSMenu()
        for (code, name) in additions {
            let item = NSMenuItem(title: name, action: #selector(Coordinator.selectAddition(_:)), keyEquivalent: "")
            item.representedObject = code; item.target = context.coordinator; menu.addItem(item)
        }
        control.setMenu(additions.isEmpty ? nil : menu, forSegment: 0)
    }
    final class Coordinator: NSObject {
        var parent: SettingsListActions
        init(_ parent: SettingsListActions) { self.parent = parent }
        @objc func selectAddition(_ item: NSMenuItem) {
            if let code = item.representedObject as? String { parent.chooseAddition?(code) }
        }
        @objc func performAction(_ control: NSSegmentedControl) {
            switch control.selectedSegment {
            case 0:
                if let menu = control.menu(forSegment: 0) {
                    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: control.bounds.maxY), in: control)
                } else { parent.add() }
            case 1 where parent.canRemove: parent.remove()
            default: break
            }
        }
    }
}

/// Shared layout for service panes: description, equal-height list and detail panels, and a bottom-aligned action bar.
struct SettingsServicePage<Sidebar: View, Detail: View, Footer: View>: View {
    let explanation: String
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var detail: Detail
    @ViewBuilder var footer: Footer
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsNote(text: explanation)
                .padding(.bottom, Design.Space.m)
            HStack(alignment: .top, spacing: Design.Space.l) {
                SettingsPanel { sidebar }.frame(width: Design.Settings.secondaryListWidth)
                SettingsPanel { detail }
            }.frame(maxHeight: .infinity)
            if Footer.self != EmptyView.self {
                HStack { footer; Spacer(minLength: 0) }.frame(height: Design.Settings.actionRowHeight)
                    .padding(.top, Design.Space.xl)
            }
        }
        .padding(.horizontal, Design.Settings.pageHorizontalInset)
        .padding(.top, Design.Space.xs)
        .padding(.bottom, Design.Space.l)
    }
}

extension SettingsServicePage where Footer == EmptyView {
    init(explanation: String, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.explanation = explanation
        self.sidebar = sidebar(); self.detail = detail(); self.footer = EmptyView()
    }
}

struct SettingsPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ThemeStyle.blockFill, in: RoundedRectangle(cornerRadius: Design.Radius.block))
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.block))
    }
}

/// Leading and trailing actions outside the panels share a single baseline without extra background or dividers.
struct SettingsServiceActionsRow<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: Design.Space.l) {
            leading.frame(width: Design.Settings.secondaryListWidth, alignment: .leading)
            trailing.frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct SettingsListPanel: View {
    let items: [SettingsSecondaryItem]
    @Binding var selection: String?
    var toggle: ((String, Bool) -> Void)? = nil
    var move: ((IndexSet, Int) -> Void)? = nil
    var body: some View {
        SettingsSecondaryList(items: items, selection: $selection, toggle: toggle, move: move)
            // The native inset list already provides top padding; avoid doubling it with outer padding.
            .padding(.bottom, Design.Space.l)
    }
}

/// Vertical detail form: labels sit above controls, and scrollbars are managed by the native overlay scroller.
struct SettingsDetailForm<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.xl) {
                header
                content
            }.frame(maxWidth: .infinity, alignment: .leading).padding(Design.Space.l)
                .background { SettingsOverlayScrollConfiguration().frame(width: 0, height: 0) }
        }.environment(\.settingsDetailMode, true).controlSize(.regular)
    }
}

struct SettingsOverlayScrollConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigurationView { ConfigurationView() }
    func updateNSView(_ view: ConfigurationView, context: Context) {}
    final class ConfigurationView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            configure()
        }
        func configure() {
            if let scroll = enclosingScrollView { OverlayScrollerPolicy.configure(scroll) }
            if let root = window?.contentView { Self.configureScrollViews(in: root) }
            DispatchQueue.main.async { [weak self] in
                guard let root = self?.window?.contentView else { return }
                Self.configureScrollViews(in: root)
            }
        }
        private static func configureScrollViews(in view: NSView) {
            if let scroll = view as? NSScrollView { OverlayScrollerPolicy.configure(scroll) }
            for child in view.subviews { configureScrollViews(in: child) }
        }
    }
}

struct SettingsLinkRow: View {
    let title: String
    let text: String
    let destination: URL
    @Environment(\.theme) private var theme
    var body: some View {
        SettingsControlRow(title) {
            Link(destination: destination) { SettingsLinkLabel(title: text) }
                .buttonStyle(.link)
                .tint(theme.isSystem ? nil : theme.swiftUI.link)
                .modifier(SettingsHoverStyle())
        }
    }
}

private struct SettingsLinkLabel: View {
    @Environment(\.theme) private var theme
    let title: String

    var body: some View {
        if theme.isSystem {
            Text(title)
        } else {
            Text(title).foregroundStyle(theme.swiftUI.link)
        }
    }
}

/// Groups status and the verify button into a compact trailing-aligned cluster, placing extra spacing only to the left of the group.
struct SettingsVerificationRow: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    let isLoading: Bool
    let message: String?
    let succeeded: Bool
    let verify: () -> Void
    var save: (() -> Void)? = nil
    var canSave = false
    var statusMessage: String? = nil
    var body: some View {
        HStack(spacing: Design.Space.s) {
            Spacer(minLength: 0)
            if isLoading {
                ProgressView().controlSize(.small)
                Text(L10n.text("verifying")).font(Design.Text.note.font).foregroundStyle(ThemeStyle.inkSecondary)
            } else if let statusMessage {
                SettingsStatus(text: statusMessage, isError: false)
            } else if let message {
                SettingsConnectionResult(message: message, succeeded: succeeded)
            }
            Button(L10n.text("verify"), action: verify).buttonStyle(.bordered)
                .controlSize(.regular).font(Design.Settings.controlTextFont)
                .frame(height: Design.Settings.controlHeight).fixedSize().disabled(isLoading)
            if let save {
                Button(L10n.text("save"), action: save).buttonStyle(.bordered)
                    .controlSize(.regular).font(Design.Settings.controlTextFont)
                    .frame(height: Design.Settings.controlHeight).fixedSize().disabled(!canSave)
            }
        }
    }
}

struct SettingsConnectionResult: View {
    let message: String
    let succeeded: Bool
    static func shortReason(_ message: String) -> String {
        guard let boundary = message.range(of: #"[。，；,\r\n]|\.\s"#, options: .regularExpression) else { return message }
        return String(message[..<boundary.lowerBound])
    }
    var displayedMessage: String { succeeded ? message : Self.shortReason(message) }

    var body: some View {
        SettingsStatus(text: displayedMessage, isError: !succeeded)
    }
}

struct SettingsDivider: View {
    var body: some View { ThemedDivider() }
}

/// Native borderless controls do not guarantee hover feedback; the background bridge only draws and never intercepts menus, key events, or accessibility.
private struct SettingsHoverStyle: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View {
        content.background { SettingsHoverBackground(isEnabled: isEnabled) }
    }
}

private struct SettingsHoverBackground: NSViewRepresentable {
    let isEnabled: Bool
    func makeNSView(context: Context) -> SettingsHoverFeedbackView { SettingsHoverFeedbackView() }
    func updateNSView(_ view: SettingsHoverFeedbackView, context: Context) { view.isEnabled = isEnabled }
}

private final class SettingsHoverFeedbackView: NSView, ThemeApplying {
    private var palette = ThemePalette.system
    func applyTheme(_ palette: ThemePalette) { self.palette = palette; needsDisplay = true }
    var isEnabled = true {
        didSet { if !isEnabled { hovered = false } }
    }
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var hoverTracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        ThemeManager.shared.register(self)
        identifier = NSUserInterfaceItemIdentifier("settingsHoverFeedback")
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hovered = false }
    }
    override func mouseEntered(with event: NSEvent) { hovered = isEnabled }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func draw(_ dirtyRect: NSRect) {
        guard hovered, isEnabled else { return }
        palette.controlHoverFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Design.Radius.control, yRadius: Design.Radius.control).fill()
    }
}

/// Shared menu trigger for service parameters: frameless text with persistent circular double-chevron indicator.
private struct SettingsMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var body: some View {
        SettingsServiceMenu(title: title, selection: $selection, options: options)
            .settingsSmartTarget("AXPopUpButton")
    }
}

/// Shared sheet for adding services; each pane only supplies existing items and the add action.
struct SettingsProviderGrid: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    let addedProviders: Set<ServiceProvider>
    let add: (ServiceProvider) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.l) {
            group(L10n.text("builtIn"), providers: ServiceProvider.builtIns)
            group(L10n.text("bringYourOwnKey"), providers: ServiceProvider.keyProviders)
        }.padding(Design.Space.l).frame(width: Design.Settings.providerGridWidth)
    }
    private func group(_ title: String, providers: [ServiceProvider]) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text(title).font(Design.Settings.groupFont).foregroundStyle(ThemeStyle.ink)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: Design.Space.m) {
                ForEach(providers) { provider in
                    let exists = provider.isBuiltIn && addedProviders.contains(provider)
                    Button { add(provider) } label: {
                        VStack(spacing: Design.Space.s) {
                            ServiceBrandIcon(provider: provider.builtInID, serviceName: provider.title, active: !exists, size: Design.Icon.brand)
                            Text(provider.title).font(Design.Settings.rowFont).lineLimit(1)
                        }.frame(maxWidth: .infinity).padding(.vertical, Design.Space.s)
                    }.buttonStyle(.bordered).disabled(exists)
                        .help(exists ? L10n.text("alreadyAdded") : L10n.format("add2", String(describing: provider.title)))
                }
            }
        }
    }
}

struct SettingsServiceEmptyState: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    var body: some View {
        VStack(spacing: Design.Space.m) {
            Image(systemName: "network").font(Design.Text.sectionTitle.font)
            Text(L10n.text("serviceListEmpty")).foregroundStyle(ThemeStyle.inkSecondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Keeps the About pane summary separate from action cards, with app icon, version, and copyright centered uniformly.
struct SettingsAboutSummary: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    static var version: String {
        let release = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.text("developmentBuild")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? L10n.text("developmentBuild")
        return "\(release) (\(build))"
    }
    var body: some View {
        VStack(spacing: Design.Space.m) {
            Image(nsImage: NSImage(named: "SevenLogo") ?? NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage)
                .resizable().scaledToFit()
                .frame(width: Design.Settings.aboutIconSize, height: Design.Settings.aboutIconSize)
                .accessibilityLabel(L10n.text("sevenAppIcon"))
            Text("Seven").font(Design.Text.sectionTitle.font)
            Text(L10n.format("version", String(describing: Self.version))).font(Design.Settings.rowFont)
            Text(L10n.text("copyright2026CrisSunAllRightsReserved"))
                .font(Design.Text.note.font).foregroundStyle(ThemeStyle.inkSecondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, Design.Space.s)
        .padding(.bottom, Design.Space.l)
    }
}

struct SettingsFolderRow:View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    let path:String
    let choose:()->Void
    var body:some View {
        SettingsButtonRow(L10n.text("saveFolder")) {
            Text(path).font(Design.Text.note.font).foregroundStyle(ThemeStyle.inkSecondary).lineLimit(1).truncationMode(.middle).help(path)
            Button(L10n.text("choose"),action:choose)
        }
    }
}
private struct SettingsToolbarIcon:View {
    let action:ScreenshotToolbarAction
    var body:some View {
        Group {
            if let image=action == .drag ? NSImage(named:NSImage.Name(action.symbol)):Design.Icon.symbol(action.symbol) {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
            }
        }.frame(width:Design.Icon.action,height:Design.Icon.action).foregroundStyle(ThemeStyle.ink)
    }
}
struct SettingsToolbarRow:View {
    @Environment(\.theme) private var theme
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    let action:ScreenshotToolbarAction
    @ObservedObject var preferences:ScreenshotToolbarPreferences
    let allManagers:[HotKeyManager]
    @Binding var recordingAction:ScreenshotToolbarAction?
    private var presented:Binding<Bool> {Binding(get:{recordingAction==action},set:{if !$0 {recordingAction=nil}})}
    var body:some View {
        HStack(spacing:Design.Space.m) {
            SettingsToolbarIcon(action:action)
            VStack(alignment:.leading,spacing:Design.Space.xs) {
                Text(action.title).font(Design.Settings.rowFont)
                if action == .edit {SettingsNote(text:L10n.text("usedForPinnedImagesAndScrollingScreenshots"))}
            }
            Spacer()
                Toggle(L10n.text("show2"),isOn:Binding(get:{preferences.item(action).visible},set:{preferences.setVisible($0,for:action)}))
                    .toggleStyle(.checkbox)
                    .tint(theme.isSystem ? nil : theme.swiftUI.switchFill)
                    .frame(width:Design.Settings.toolbarVisibilityWidth)
                    .accessibilityLabel(L10n.format("show3", String(describing: action.title)))
            HStack(spacing:Design.Space.s) {
                if action.acceptsKey {
                    SettingsShortcutButton(keys:[preferences.hint(action)],title:action.title) {
                        recordingAction = action
                    }
                        .popover(isPresented:presented,arrowEdge:.bottom) {ShortcutCaptureView(action:action.title,target:.tool(action,preferences),allManagers:allManagers)}
                } else if let labels=action.fixedKeyLabels {KeycapRow(keys:labels,style:.fixed)}
                else {Text(action == .drag ? L10n.text("dragWithMouse"):"—").font(Design.Text.note.font).foregroundStyle(ThemeStyle.inkSecondary)}
            }.frame(width:Design.Settings.toolbarKeyWidth,alignment:.trailing)
        }
    }
}
struct SettingsShadowColorRow:View {
    let title:String
    @Binding var hex:String
    var body:some View {
        HStack {
            Text(title);Spacer()
            SettingsColorSelection(hex:$hex).frame(width:Design.ScreenshotEditor.toolbarControlHeight,height:Design.ScreenshotEditor.toolbarControlHeight).accessibilityLabel(title)
        }
    }
}

private struct SettingsColorSelection:NSViewRepresentable {
    @Binding var hex:String
    func makeNSView(context:Context)->ColorSelectionWell {ColorSelectionWell(frame:.zero)}
    func updateNSView(_ view:ColorSelectionWell,context:Context) {
        view.onColorChange=nil
        view.color=Design.ScreenshotShadow.color(rgb:ScreenshotShadowPreferences.rgb(hex),alpha:1)
        view.onColorChange={color in hex=ScreenshotShadowPreferences.hex(color)}
    }
}
