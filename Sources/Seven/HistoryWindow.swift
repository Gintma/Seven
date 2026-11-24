import AppKit
import SwiftUI

@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private var makeWindow: (() -> NSWindow)?
    private let store: HistoryStore

    init(store: HistoryStore) {
        self.store = store
        makeWindow = {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = L10n.text("history.title")
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 720, height: 500)
            window.setFrameAutosaveName("SevenHistoryWindow")
            window.contentView = NSHostingView(rootView: HistoryView(store: store))
            window.center()
            return window
        }
        super.init(window: nil)
    }

    // 声明按需加载身份；loadWindow 直接构建窗口，不读取 nib 文件。
    override var windowNibName: NSNib.Name? { NSNib.Name("HistoryWindow") }

    override func loadWindow() {
        guard let makeWindow else { return }
        window = makeWindow()
        window?.delegate = self
        self.makeWindow = nil
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        store.setBrowsing(true)
        super.showWindow(sender)
    }

    func windowWillClose(_ notification: Notification) {
        store.setBrowsing(false)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, favorites
    var id: Self { self }
    var title: String { L10n.text(rawValue) }
}

private struct HistoryFilterControl: View {
    @Environment(\.theme) private var theme
    @Binding var filter: HistoryFilter

    var body: some View {
        if theme.isSystem {
            Picker(L10n.text("range"), selection: $filter) {
                ForEach(HistoryFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } else {
            SettingsSegmentedControl(selection: $filter,
                                     options: HistoryFilter.allCases.map { .init(value: $0, title: $0.title) },
                                     accessibilityLabel: L10n.text("range"))
        }
    }
}

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    @State private var selection: UUID?
    @State private var searchText = ""
    @State private var filter: HistoryFilter = .all
    @State private var pendingDelete: UUID?
    @State private var confirmingClear = false

    private func filteredRecords(from records: [TranslationRecord]) -> [TranslationRecord] {
        records.filter { record in
            let matchesFilter = filter == .all || record.isFavorite
            let matchesSearch = searchText.isEmpty ||
                record.sourceText.localizedCaseInsensitiveContains(searchText) ||
                record.translatedText.localizedCaseInsensitiveContains(searchText)
            return matchesFilter && matchesSearch
        }
    }

    private func selectedRecord(in records: [TranslationRecord]) -> TranslationRecord? {
        guard let selection else { return records.first }
        return records.first { $0.id == selection }
    }

    var body: some View { ThemedContent(content: navigation) }

    private var navigation: some View {
        let records = store.browsingRecords
        let filtered = filteredRecords(from: records)
        let hasRecords = !records.isEmpty
        return NavigationSplitView {
            VStack(spacing: Design.Space.s) {
                HistoryFilterControl(filter: $filter)
                .padding(.horizontal, Design.Layout.cardInset)
                List(filtered, selection: $selection) { record in
                    historyRow(record)
                        .themeSidebarRow(selected: record.id == selection).tag(record.id)
                }
                .themeSidebar(sourceListOnly: false)
                .overlay {
                    if filtered.isEmpty {
                        emptyState(
                            searchText.isEmpty ? L10n.text("noHistoryYet") : L10n.text("noSearchResults"),
                            systemImage: searchText.isEmpty ? "clock" : "magnifyingglass"
                        )
                    }
                }
            }
            .settingsOverlayScrollbars()
            .searchable(text: $searchText,
                        prompt: Text(L10n.text("searchSourceTextOrTranslations")).foregroundStyle(ThemeStyle.placeholder))
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            if let record = selectedRecord(in: filtered) {
                recordDetail(record)
            } else {
                emptyState(L10n.text("selectAnEntry"), systemImage: "text.bubble").themeDetailSurface()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button(L10n.text("exportJSON")) { export(.json) }
                    Button(L10n.text("exportMarkdown")) { export(.markdown) }
                } label: { Label(L10n.text("export"), systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { confirmingClear = true } label: {
                    Label(L10n.text("clearHistory"), systemImage: "trash")
                }
                .disabled(!hasRecords)
            }
        }
        .confirmationDialog(L10n.text("deleteThisHistoryEntry"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(L10n.text("delete"), role: .destructive) {
                if let pendingDelete { store.delete(pendingDelete) }
                self.pendingDelete = nil
            }
            Button(L10n.text("cancel"), role: .cancel) { pendingDelete = nil }
        }
        .confirmationDialog(L10n.text("clearAllHistory"), isPresented: $confirmingClear) {
            Button(L10n.text("clearHistory"), role: .destructive) { store.clear(); selection = nil }
            Button(L10n.text("cancel"), role: .cancel) {}
        }
        .environment(\.locale, L10n.locale)
        .onAppear { if selection == nil { selection = filtered.first?.id } }
        .onChange(of: searchText) { normalizeSelection(in: filtered) }
        .onChange(of: filter) { normalizeSelection(in: filtered) }
        .onChange(of: store.revision) { normalizeSelection(in: filtered) }
    }

    private func historyRow(_ record: TranslationRecord) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack {
                Text(record.sourceText.replacingOccurrences(of: "\n", with: " "))
                    .lineLimit(1)
                Spacer()
                if record.isFavorite { Image(systemName: "star.fill").foregroundStyle(ThemeStyle.favorite) }
            }
            HStack {
                Text(LanguageCatalog.displayName(stored: record.targetLanguage))
                Spacer()
                Text(record.createdAt, style: .relative)
            }
            .font(.caption)
            .foregroundStyle(ThemeStyle.nativeSecondary)
        }
        .padding(.vertical, Design.Space.xs)
    }

    private func recordDetail(_ record: TranslationRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(record.mode.title).font(.headline)
                Text("· \(LanguageCatalog.displayName(stored: record.targetLanguage))").foregroundStyle(ThemeStyle.nativeSecondary)
                Spacer()
                Button { store.toggleFavorite(record.id) } label: {
                    Image(systemName: record.isFavorite ? "star.fill" : "star")
                }
                .help(record.isFavorite ? L10n.text("removeFromFavorites") : L10n.text("addToFavorites"))
                .accessibilityLabel(record.isFavorite ? L10n.text("removeFromFavorites") : L10n.text("addToFavorites"))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.translatedText, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .help(L10n.text("copyTranslation"))
                .accessibilityLabel(L10n.text("copyTranslation"))
                Button(role: .destructive) { pendingDelete = record.id } label: {
                    Image(systemName: "trash")
                }
                .help(L10n.text("deleteEntry"))
                .accessibilityLabel(L10n.text("deleteEntry"))
            }
            .padding(Design.Layout.pageInset)
            ThemedDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.xl) {
                    historyText(L10n.text("sourceText"), record.sourceText)
                    historyText(L10n.text("translation"), record.translatedText)
                }
                .padding(Design.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(ThemeStyle.background)
    }

    private func historyText(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(ThemeStyle.nativeSecondary)
            Text(text).textSelection(.enabled).font(Design.Text.content.font).lineSpacing(Design.Text.bodyLineSpacing)
        }
    }

    private func emptyState(_ title: String, systemImage: String) -> some View {
        VStack(spacing: Design.Space.s) {
            Image(systemName: systemImage).font(.system(size: Design.Icon.hero, weight: .light))
            Text(title).font(.headline)
        }
        .foregroundStyle(ThemeStyle.nativeSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func export(_ format: HistoryExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L10n.format("sevenHistory", String(describing: format.fileExtension))
        panel.allowedContentTypes = format == .json ? [.json] : [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        export(to: url, format: format) { $0.runModal() }
    }

    // Presentation is injectable so failure feedback can be tested without a modal panel.
    func export(to url: URL, format: HistoryExportFormat, presentFailure: (NSAlert) -> Void) {
        do {
            try store.export(filteredRecords(from: store.records), to: url, format: format)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = L10n.text("exportFailed")
            alert.informativeText = L10n.text("checkSavePermissionsAndFreeSpace")
            alert.addButton(withTitle: L10n.text("ok"))
            presentFailure(alert)
        }
    }

    private func normalizeSelection(in filteredRecords: [TranslationRecord]) {
        guard store.isBrowsing else { return }
        guard let current = selection, filteredRecords.contains(where: { $0.id == current }) else {
            self.selection = filteredRecords.first?.id
            return
        }
    }
}
