import AppKit
import SwiftUI

struct HistoryRecordDetail: View {
    let record: TranslationRecord
    let date: String
    let isFavorite: Bool
    let speech: SpeechController
    let toggleFavorite: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Design.Space.m) {
                Text(date)
                    .monospacedDigit()
                    .foregroundStyle(ThemeStyle.nativeSecondary)
                Spacer()
                let favoriteLabel = L10n.text(isFavorite ? "removeFromFavorites" : "addToFavorites")
                Button(action: toggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? ThemeStyle.favorite : ThemeStyle.nativeSecondary)
                }
                .help(favoriteLabel)
                .accessibilityLabel(favoriteLabel)
                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                }
                .help(L10n.text("deleteEntry"))
                .accessibilityLabel(L10n.text("deleteEntry"))
            }
            .font(.callout)
            .buttonStyle(.borderless)
            .padding(Design.Layout.pageInset)
            ThemedDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Design.Space.m) {
                    HistoryTextCard(
                        title: L10n.text("sourceText"), text: record.sourceText,
                        language: record.sourceLanguage, recordID: record.id, provider: nil, speech: speech
                    )
                    languageDirection
                    ForEach(record.results) { result in
                        HistoryTextCard(
                            title: result.providerName, text: result.translatedText,
                            language: result.providerID == .ecdict ? nil : record.targetLanguage,
                            recordID: record.id, provider: result.providerID, speech: speech
                        )
                    }
                }
                .padding(Design.Layout.pageInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(ThemeStyle.background)
    }

    private var languageDirection: some View {
        let source = LanguageCatalog.displayName(stored: record.sourceLanguage)
        let target = LanguageCatalog.displayName(stored: record.targetLanguage)
        return HStack(spacing: Design.Space.s) {
            Text(source)
            Image(systemName: "chevron.right").accessibilityHidden(true)
            Text(target)
            Spacer()
            if record.mode != .translate {
                Text(record.mode.title)
                    .padding(.horizontal, Design.Space.s)
                    .padding(.vertical, Design.Space.xs)
                    .background(ThemeStyle.background, in: RoundedRectangle(cornerRadius: Design.Radius.control))
            }
        }
        .font(.callout)
        .foregroundStyle(ThemeStyle.nativeSecondary)
        .padding(Design.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeStyle.blockFill, in: RoundedRectangle(cornerRadius: Design.Radius.block))
        .accessibilityElement(children: .combine)
    }
}

private struct HistoryTextCard: View {
    let title: String
    let text: String
    let language: String?
    let recordID: UUID
    let provider: TranslationProviderID?
    let speech: SpeechController

    @State private var copyCount = 0
    @State private var showsCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(spacing: Design.Space.s) {
                if let provider { ServiceBrandIcon(provider: provider, serviceName: title, active: true) }
                Text(title)
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                HistorySpeechButton(
                    speech: speech, content: .history(recordID: recordID, provider: provider),
                    text: text, language: language
                )
                let copyLabel = L10n.text(provider == nil ? "copySourceText" : "copyTranslation")
                Button {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(text, forType: .string) {
                        showsCopied = true
                        copyCount &+= 1
                    }
                } label: {
                    Image(systemName: showsCopied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(showsCopied ? ThemeStyle.accentInk : ThemeStyle.nativeSecondary)
                }
                .help(copyLabel)
                .accessibilityLabel(copyLabel)
            }
            .buttonStyle(.borderless)

            Text(text)
                .textSelection(.enabled)
                .font(Design.Text.content.font)
                .lineSpacing(Design.Text.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Design.Space.m)
        .background(ThemeStyle.blockFill, in: RoundedRectangle(cornerRadius: Design.Radius.block))
        .task(id: copyCount) {
            guard showsCopied else { return }
            do { try await Task.sleep(for: .seconds(Design.Motion.hold)) }
            catch { return }
            showsCopied = false
        }
    }
}

private struct HistorySpeechButton: View {
    @ObservedObject var speech: SpeechController
    let content: SpeechContent
    let text: String
    let language: String?

    var body: some View {
        let canSpeak = speech.canSpeak(text: text, declaredLanguage: language)
        let label = canSpeak ? speech.label(for: content) :
            speech.availabilityLabel(content: content, text: text, declaredLanguage: language)
        Button {
            speech.toggle(content: content, text: text, declaredLanguage: language)
        } label: {
            if speech.appearance(for: content) == .loading {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: speech.icon(for: content))
            }
        }
        .foregroundStyle(ThemeStyle.nativeSecondary)
        .disabled(!canSpeak)
        .help(label)
        .accessibilityLabel(label)
    }
}
