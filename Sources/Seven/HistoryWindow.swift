import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private var makeWindow: (() -> NSWindow)?
    private let store: HistoryStore
    private let speech: SpeechController

    init(store: HistoryStore, speech: SpeechController) {
        self.store = store
        self.speech = speech
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
            window.contentView = NSHostingView(rootView: HistoryView(store: store, speech: speech))
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
        speech.stopHistoryPlayback()
        store.setBrowsing(false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        speech.stopHistoryPlayback()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HistoryView: View {
    private struct PendingDeletion {
        let id: UUID
        let collection: HistoryCollection
    }

    @ObservedObject var store: HistoryStore
    let speech: SpeechController
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    @State private var selection: UUID?
    @State private var searchText = ""
    @State private var collection: HistoryCollection = .history
    @State private var pendingDeletion: PendingDeletion?
    @State private var showingDelete = false
    @State private var confirmingClear = false

    var body: some View {
        // Keep the navigation state, while releasing snapshot-backed views when the window closes.
        if store.isBrowsing {
            ThemedContent(content: navigation).environment(\.locale, L10n.locale)
        }
    }

    private var navigation: some View {
        let filtered = store.records(in: collection, matching: searchText)
        let hasRecords = !store.browsingRecords(in: collection).isEmpty
        let favoriteIDs = collection == .history ? Set(store.browsingRecords(in: .favorites).map(\.id)) : []
        let current = filtered.first { $0.id == selection } ?? filtered.first
        let date = HistoryDatePresentation()

        return NavigationSplitView {
            VStack(alignment: .leading, spacing: Design.Space.s) {
                HistoryCollectionPicker(collection: $collection)
                    .padding(.horizontal, Design.Layout.cardInset)
                Text(L10n.format("history.itemCount", Int64(filtered.count)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(ThemeStyle.nativeSecondary)
                    .padding(.horizontal, Design.Layout.pageInset)
                List(filtered, selection: $selection) { record in
                    historyRow(
                        record, date: date.row(record.createdAt),
                        isFavorite: favoriteIDs.contains(record.id)
                    )
                    .themeSidebarRow(selected: record.id == selection)
                    .tag(record.id)
                }
                .themeSidebar(sourceListOnly: false)
                .overlay {
                    if filtered.isEmpty {
                        emptyState(
                            hasRecords ? L10n.text("noSearchResults") : collection.emptyMessage,
                            systemImage: hasRecords ? "magnifyingglass" : collection.icon
                        )
                        .allowsHitTesting(false)
                    }
                }
            }
            .settingsOverlayScrollbars()
            .searchable(text: $searchText,
                        prompt: Text(L10n.text("searchSourceTextOrTranslations")).foregroundStyle(ThemeStyle.placeholder))
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            if let current {
                HistoryRecordDetail(
                    record: current, date: date.detail(current.createdAt),
                    isFavorite: collection == .favorites || favoriteIDs.contains(current.id),
                    speech: speech,
                    toggleFavorite: { store.toggleFavorite(current.id) },
                    delete: {
                        pendingDeletion = PendingDeletion(id: current.id, collection: collection)
                        showingDelete = true
                    }
                )
                .id(current.id)
            } else {
                emptyState(L10n.text("selectAnEntry"), systemImage: "text.bubble").themeDetailSurface()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button(L10n.text("exportJSON")) { export(.json, collection: collection) }
                    Button(L10n.text("exportMarkdown")) { export(.markdown, collection: collection) }
                } label: { Label(L10n.text("export"), systemImage: "square.and.arrow.up") }
                .disabled(!hasRecords)

                if collection == .history {
                    Button(role: .destructive) { confirmingClear = true } label: {
                        Label(L10n.text("clearHistory"), systemImage: "trash")
                    }
                    .disabled(!hasRecords)
                }
            }
        }
        .alert(
            L10n.text(pendingDeletion?.collection == .favorites ? "history.deleteFavorite" : "deleteThisHistoryEntry"),
            isPresented: $showingDelete, presenting: pendingDeletion
        ) { pending in
            Button(L10n.text("delete"), role: .destructive) { store.delete(pending.id, from: pending.collection) }
            Button(L10n.text("cancel"), role: .cancel) {}
        }
        .alert(L10n.text("clearAllHistory"), isPresented: $confirmingClear) {
            Button(L10n.text("clearHistory"), role: .destructive) { store.clearHistory() }
            Button(L10n.text("cancel"), role: .cancel) {}
        }
        .onChange(of: current?.id, initial: true) { _, currentID in
            speech.stopHistoryPlayback()
            selection = currentID
        }
        .onChange(of: collection) {
            speech.stopHistoryPlayback()
            selection = current?.id
        }
    }

    private func historyRow(_ record: TranslationRecord, date: String, isFavorite: Bool) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            Text(record.sourceText.replacingOccurrences(of: "\n", with: " "))
                .lineLimit(2)
            HStack(spacing: Design.Space.xs) {
                Text(date)
                    .monospacedDigit()
                if isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(ThemeStyle.favorite)
                        .accessibilityLabel(L10n.text("history.favorites"))
                }
            }
            .font(.caption)
            .foregroundStyle(ThemeStyle.nativeSecondary)
        }
        .padding(.vertical, Design.Space.xs)
    }

    private func emptyState(_ title: String, systemImage: String) -> some View {
        VStack(spacing: Design.Space.s) {
            Image(systemName: systemImage)
                .font(.system(size: Design.Icon.hero, weight: .light))
                .accessibilityHidden(true)
            Text(title).font(.headline)
        }
        .foregroundStyle(ThemeStyle.nativeSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func export(_ format: HistoryExportFormat, collection: HistoryCollection) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L10n.format(collection.exportNameKey, format.fileExtension)
        panel.allowedContentTypes = format == .json ? [.json] : [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        export(collection, to: url, format: format) { $0.runModal() }
    }

    // Presentation is injectable so failure feedback can be tested without a modal panel.
    func export(_ collection: HistoryCollection, to url: URL, format: HistoryExportFormat, presentFailure: (NSAlert) -> Void) {
        do {
            try store.export(collection, to: url, format: format)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = L10n.text("exportFailed")
            alert.informativeText = L10n.text("checkSavePermissionsAndFreeSpace")
            alert.addButton(withTitle: L10n.text("ok"))
            presentFailure(alert)
        }
    }
}

private struct HistoryCollectionPicker: View {
    @Environment(\.theme) private var theme
    @Binding var collection: HistoryCollection

    var body: some View {
        if theme.isSystem {
            Picker(L10n.text("range"), selection: $collection) {
                ForEach(HistoryCollection.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } else {
            SettingsSegmentedControl(
                selection: $collection,
                options: HistoryCollection.allCases.map { .init(value: $0, title: $0.title) },
                accessibilityLabel: L10n.text("range")
            )
        }
    }
}
