import AppKit
import SwiftUI

/// Uses the translation panel's drawn checkmark without changing the card header's layout.
struct HistoryCopyButton: NSViewRepresentable {
    let text: String
    let label: String
    var pasteboard: NSPasteboard = .general

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AnimatedSymbolButton {
        let button = AnimatedSymbolButton(symbol: "doc.on.doc", label: label, weight: .medium, scale: .small)
        button.target = context.coordinator
        button.action = #selector(Coordinator.copy(_:))
        return button
    }

    func updateNSView(_ button: AnimatedSymbolButton, context: Context) {
        context.coordinator.copyText = {
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
        button.updateLocalizedLabel(label)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnimatedSymbolButton, context: Context) -> CGSize? {
        CGSize(width: Design.Icon.cardActionSize, height: Design.Icon.cardActionSize)
    }

    final class Coordinator: NSObject {
        var copyText: (() -> Bool)?

        @objc func copy(_ sender: AnimatedSymbolButton) {
            if copyText?() == true { sender.flashConfirmation() }
        }
    }
}
