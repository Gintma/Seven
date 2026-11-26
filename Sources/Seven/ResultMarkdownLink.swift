import AppKit

@MainActor
enum ResultMarkdownLink {
    static func open(
        _ destination: URL, confirm: (URL, @escaping @MainActor (Bool) -> Void) -> Void,
        using opener: @escaping @MainActor (URL) -> Void
    ) {
        guard let url = ResultMarkdownDocument.safeLink(destination.absoluteString) else { return }
        confirm(url) { accepted in
            if accepted { opener(url) }
        }
    }

    static func confirm(_ destination: URL, in window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        open(destination, confirm: { url, decision in
            let alert = NSAlert()
            alert.messageText = L10n.text("translation.markdown.openLink")
            alert.informativeText = String(url.absoluteString.prefix(300))
            alert.addButton(withTitle: L10n.text("cancel"))
            alert.addButton(withTitle: L10n.text("open"))
            alert.beginSheetModal(for: window) { decision($0 == .alertSecondButtonReturn) }
        }, using: { NSWorkspace.shared.open($0) })
    }
}
