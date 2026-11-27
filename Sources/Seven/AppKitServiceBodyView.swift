import AppKit
import Combine
import CoreText

@MainActor
final class AppKitServiceBodyView: FlippedView, NSTextViewDelegate, ThemeApplying {
    private var palette = ThemePalette.system
    private static let paragraphGap = NSAttributedString.Key("SevenExamplePairGap")
    struct DictionaryPreferences: Equatable {
        let pronunciations: Bool
        let definitions: Bool
        let phrases: Bool
        let examples: Bool

        @MainActor init(_ model: TranslationModel) {
            pronunciations = model.youdaoShowsPronunciations
            definitions = model.youdaoShowsDefinitions
            phrases = model.youdaoShowsPhrases
            examples = model.youdaoShowsExamples
        }
    }

    private let model: TranslationModel
    private let textView = StreamingResultTextView()
    private let actions = NSStackView()
    private var result: TranslationServiceResult?
    private var renderedPlainText = ""
    private var rendersPlainTranslation = false
    private var markdownRequestID: UUID?
    private var lastMarkdown: (MarkdownSnapshot, MarkdownParseResult)?
    private var isShowingRichMarkdown = false
    private var markdownNeedsRestyle = false
    private var wasMarkdownEnabled = false
    private var loggedMarkdownFallback: ResultMarkdownDocument.Fallback?
    private lazy var markdownUpdates = ResultMarkdownUpdates { [weak self] snapshot, parsed in
        self?.receiveMarkdown(snapshot, parsed: parsed)
    }
    private var actionSignature = ""
    private var measuredWidth: CGFloat = 0
    private var renderedMarkdownWidth: CGFloat = 0
    private var cachedTextHeight: CGFloat = 0
    private var textMeasurementDirty = true
    private var pronunciationButtons: [SpeechContent: SpeechToggleButton] = [:]
    private var dictionaryTerms: [String: String] = [:]
    private var pronunciationLocations: [SpeechContent: Int] = [:]
    private var speechCancellable: AnyCancellable?
    var onVisibleTextChange: (() -> Void)?
    var onMarkdownReflow: (() -> Void)?
    var onMarkdownSpeechChange: (() -> Void)?
    var isRevealing: Bool { textView.isRevealing }
    var renderingSuspended: Bool {
        get { textView.renderingSuspended }
        set {
            if textView.renderingSuspended != newValue {
                textView.renderingSuspended = newValue
                textMeasurementDirty = true
                if newValue {
                    if markdownRequestID != nil { markdownUpdates.suspend() }
                    stopPronunciation()
                }
            }
        }
    }

    init(model: TranslationModel) {
        self.model = model
        super.init(frame: .zero)
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.delegate = self
        textView.linkTextAttributes = [.underlineStyle: 0]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.autoresizingMask = [.width]
        textView.onVisibleTextChange = { [weak self] in
            self?.textMeasurementDirty = true
            self?.needsLayout = true
            self?.onVisibleTextChange?()
        }
        addSubview(textView)

        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Design.Space.s
        addSubview(actions)
        speechCancellable = model.speech.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.updatePronunciationButtons() }
        }
        ThemeManager.shared.register(self)
    }

    func applyTheme(_ palette: ThemePalette) {
        self.palette = palette
        textView.applyTheme(palette)
        if isShowingRichMarkdown {
            markdownNeedsRestyle = true
            if !renderingSuspended, let (snapshot, parsed) = lastMarkdown {
                displayMarkdown(snapshot, parsed: parsed)
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    func invalidateLocalizedActions() {
        actionSignature = ""
        textView.refreshMarkdownCodeLabels()
    }

    func apply(_ result: TranslationServiceResult) {
        let previousPhase = self.result?.phase
        self.result = result
        updateText(for: result, previousPhase: previousPhase)
        let nextActionSignature = [
            String(describing: result.phase),
            result.dictionaryEntry?.headword ?? "",
            result.dictionaryEntry?.pronunciations.map { $0.label + $0.value }.joined() ?? "",
            result.appleMissingLanguages.joined(separator: ","),
            String(model.youdaoShowsPronunciations)
        ].joined(separator: "|")
        if actionSignature != nextActionSignature {
            actionSignature = nextActionSignature
            rebuildActions(for: result)
        }
        updatePronunciationButtons()
        needsLayout = true
    }

    private func updateText(for result: TranslationServiceResult, previousPhase: TranslationResultPhase?) {
        guard !renderingSuspended else { return }
        dictionaryTerms.removeAll()
        pronunciationLocations.removeAll()
        let plain = result.dictionaryEntry == nil && (result.phase == .streaming || result.phase == .success)
        let markdownEnabled = model.rendersCustomResultsAsMarkdown
        let displayChanged = wasMarkdownEnabled != markdownEnabled
        wasMarkdownEnabled = markdownEnabled

        if markdownRequestID != result.markdownOutput?.requestID {
            if markdownRequestID != nil { markdownUpdates.reset() }
            if markdownRequestID != nil || result.markdownOutput != nil {
                lastMarkdown = nil
                loggedMarkdownFallback = nil
                isShowingRichMarkdown = false
                markdownNeedsRestyle = false
                textView.usesSimpleTextCursor = false
                rendersPlainTranslation = false
                renderedPlainText = ""
                textView.replace(with: NSAttributedString(string: ""))
            }
            markdownRequestID = result.markdownOutput?.requestID
        }

        textView.copiesSelectionAsPlainText = plain && result.markdownOutput != nil && markdownEnabled
        if let output = result.markdownOutput, !result.text.isEmpty {
            markdownUpdates.submit(MarkdownSnapshot(output: output, text: result.text))
            if plain && markdownEnabled {
                if let (snapshot, parsed) = lastMarkdown, displayChanged || markdownNeedsRestyle {
                    displayMarkdown(snapshot, parsed: parsed)
                }
                return
            }
        }

        if plain {
            updatePlainText(result.text, progressively: result.phase == .streaming
                            || previousPhase == .streaming || textView.isRevealing)
        } else {
            isShowingRichMarkdown = false
            rendersPlainTranslation = false
            renderedPlainText = ""
            textView.usesSimpleTextCursor = false
            textView.replace(with: attributedText(for: result))
        }
    }

    private func updatePlainText(_ text: String, progressively: Bool, batches: Bool = false) {
        let source = text as NSString
        if isShowingRichMarkdown {
            let limit = ResultMarkdownDocument.maximumSourceBytes
            let seedLength = batches && source.length > limit
                ? NSMaxRange(source.rangeOfComposedCharacterSequence(at: limit - 1)) : source.length
            let seed = source.substring(to: seedLength)
            replaceMarkdownText(styled(seed, font: Design.Text.content.nsFont, color: .ink, lineSpacing: 6))
            isShowingRichMarkdown = false
            rendersPlainTranslation = true
            renderedPlainText = seed
        }

        let continues = rendersPlainTranslation && source.hasPrefix(renderedPlainText)
        let previousCount = continues ? (renderedPlainText as NSString).length : 0
        if !continues { textView.replace(with: NSAttributedString(string: "")) }
        let suffix = source.substring(from: previousCount)
        if !suffix.isEmpty {
            textView.append(styled(suffix, font: Design.Text.content.nsFont, color: .ink, lineSpacing: 6),
                            progressively: progressively, batches: batches)
        }
        rendersPlainTranslation = true
        renderedPlainText = text
    }

    private func receiveMarkdown(_ snapshot: MarkdownSnapshot, parsed: MarkdownParseResult) {
        guard !renderingSuspended, let result, result.markdownOutput?.requestID == snapshot.output.requestID,
              let current = model.serviceResults.first(where: { $0.id == result.id })?.markdownOutput,
              current.requestID == snapshot.output.requestID,
              current.status != .completed || snapshot.output.status == .completed else { return }
        lastMarkdown = (snapshot, parsed)
        if case .failure(let reason) = parsed.document, loggedMarkdownFallback != reason {
            loggedMarkdownFallback = reason
            Task { [logger = model.logger] in
                await logger.record(.info, "translation_markdown_fallback", metadata: [
                    "elapsed_ms": String(parsed.elapsedMilliseconds), "bytes": String(parsed.byteCount),
                    "reason": reason.rawValue
                ])
            }
        }
        if model.rendersCustomResultsAsMarkdown, result.phase == .streaming || result.phase == .success {
            displayMarkdown(snapshot, parsed: parsed)
        }
        onMarkdownSpeechChange?()
    }

    private func displayMarkdown(_ snapshot: MarkdownSnapshot, parsed: MarkdownParseResult) {
        markdownNeedsRestyle = false
        switch parsed.document {
        case .success(let document):
            isShowingRichMarkdown = true
            rendersPlainTranslation = false
            renderedPlainText = ""
            textView.usesSimpleTextCursor = false
            let width = measuredWidth > 0 ? measuredWidth : TranslationPanelSize.defaultWidth - Design.Space.l * 2 - Design.Space.blockInset * 2
            renderMarkdown(document, width: width)
        case .failure:
            textView.usesSimpleTextCursor = true
            updatePlainText(snapshot.text, progressively: false, batches: true)
        }
    }

    private func renderMarkdown(_ document: ResultMarkdownDocument, width: CGFloat) {
        renderedMarkdownWidth = width
        let text = ResultMarkdownRenderer(palette: palette).render(document, availableWidth: width)
        replaceMarkdownText(text, markdown: true)
    }

    private func replaceMarkdownText(_ text: NSAttributedString, markdown: Bool = false) {
        onMarkdownReflow?()
        textView.replace(with: text, preservingSelection: true, markdown: markdown)
    }

    func speechText(for result: TranslationServiceResult) -> String {
        guard let output = result.markdownOutput else { return result.text }
        guard !result.text.isEmpty, let (snapshot, parsed) = lastMarkdown,
              snapshot.output.requestID == output.requestID,
              case .success(let document) = parsed.document else { return "" }
        return document.speechText
    }

    func readingAnchor(at y: CGFloat, in document: NSView) -> (() -> CGFloat?)? {
        textView.readingAnchor(at: y, in: document)
    }

    func setAccessibilityExposed(_ exposed: Bool) {
        textView.setAccessibilityHidden(!exposed)
        actions.setAccessibilityHidden(!exposed)
        for view in actions.arrangedSubviews {
            view.setAccessibilityHidden(!exposed)
        }
        for button in pronunciationButtons.values { button.setAccessibilityHidden(!exposed) }
    }

    func measuredHeight(for width: CGFloat) -> CGFloat {
        let safeWidth = max(120, width)
        if abs(measuredWidth - safeWidth) > 0.5 {
            measuredWidth = safeWidth
            textView.setFrameSize(NSSize(width: safeWidth, height: max(1, textView.frame.height)))
            textView.textContainer?.containerSize = NSSize(
                width: safeWidth, height: CGFloat.greatestFiniteMagnitude
            )
            // 词形按整组换行；宽度变化时重排正文和按钮位置，原始结果不变。
            if let result, result.dictionaryEntry != nil {
                updateText(for: result, previousPhase: result.phase)
            } else if isShowingRichMarkdown, !renderingSuspended, abs(renderedMarkdownWidth - safeWidth) > 0.5,
                      let (_, parsed) = lastMarkdown, case .success(let document) = parsed.document,
                      document.blocks.contains(where: { if case .table = $0.content { return true }; return false }) {
                renderMarkdown(document, width: safeWidth)
            }
            textMeasurementDirty = true
        }
        if textMeasurementDirty, let container = textView.textContainer,
           let manager = textView.layoutManager {
            if result?.dictionaryEntry != nil { normalizeVisibleParagraphGaps(manager: manager, container: container) }
            manager.ensureLayout(for: container)
            _ = manager.glyphRange(for: container)
            let used = manager.usedRect(for: container)
            let extra = manager.extraLineFragmentRect
            // This line is TextKit's caret position after the last newline, with no glyphs.
            let bottom = isShowingRichMarkdown && !extra.isEmpty && manager.extraLineFragmentTextContainer === container
                ? min(used.maxY, extra.minY) : used.maxY
            cachedTextHeight = ceil(max(0, bottom - used.minY))
            textMeasurementDirty = false
        }
        let textHeight = cachedTextHeight
        let actionsHeight: CGFloat = actions.arrangedSubviews.isEmpty ? 0 : 28
        return textHeight + (textHeight > 0 && actionsHeight > 0 ? 10 : 0) + actionsHeight
    }

    /// 字体行框的上下留白不属于用户指定的可见间距，按实际字面范围补偿。
    private func normalizeVisibleParagraphGaps(manager: NSLayoutManager, container: NSTextContainer) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        for _ in 0..<3 {
            manager.ensureLayout(for: container)
            func ink(at character: Int) -> CGRect {
                let glyph = manager.glyphIndexForCharacter(at: character)
                var glyphs = NSRange()
                let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
                let baseline = line.minY + manager.location(forGlyphAt: glyph).y
                let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                let bounds = CTLineGetImageBounds(CTLineCreateWithAttributedString(storage.attributedSubstring(from: characters)), nil)
                return CGRect(x: 0, y: baseline-bounds.maxY, width: bounds.width, height: bounds.height)
            }
            var updates: [(NSRange, NSMutableParagraphStyle)] = []
            storage.enumerateAttribute(Self.paragraphGap, in: NSRange(location: 0, length: storage.length)) { desired, range, _ in
                guard let desired = desired as? CGFloat else { return }
                let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: range.location, length: 0))
                let next = NSMaxRange(paragraph)
                guard next < storage.length, paragraph.length > 1 else { return }
                let previousInk = ink(at: next-2), nextInk = ink(at: next)
                let difference = desired - (nextInk.minY-previousInk.maxY)
                guard abs(difference) > 0.1 else { return }
                let style = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.paragraphSpacing += difference
                updates.append((paragraph, style))
            }
            guard !updates.isEmpty else { break }
            for (range, style) in updates { storage.addAttribute(.paragraphStyle, value: style, range: range) }
        }
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width)
        let height = measuredHeight(for: width)
        let actionsHeight: CGFloat = actions.arrangedSubviews.isEmpty ? 0 : 28
        let textHeight = max(0, height - actionsHeight - (actionsHeight > 0 ? 10 : 0))
        textView.frame = NSRect(x: 0, y: 0, width: width, height: textHeight)
        actions.frame = NSRect(
            x: 0,
            y: textHeight + (textHeight > 0 && actionsHeight > 0 ? 10 : 0),
            width: width,
            height: actionsHeight
        )
        positionPronunciationButtons()
    }

    private func positionPronunciationButtons() {
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        manager.ensureLayout(for: container)
        for (content, button) in pronunciationButtons {
            guard let location = pronunciationLocations[content] else { button.isHidden = true; continue }
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            var lineGlyphs = NSRange()
            let line = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: &lineGlyphs)
            let baseline = line.minY + manager.location(forGlyphAt: glyphs.location).y
            let characters = manager.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
            let lineText = textView.attributedString().attributedSubstring(from: characters)
            let ink = CTLineGetImageBounds(CTLineCreateWithAttributedString(lineText), nil)
            let visualCenter = baseline - ink.midY
            let side = Design.Dictionary.pronunciationButtonSize
            button.frame = textView.convert(CGRect(x: rect.minX + textView.textContainerOrigin.x,
                                                   y: visualCenter - side / 2 + textView.textContainerOrigin.y,
                                                   width: side, height: side), to: self)
            button.isHidden = renderingSuspended
        }
        textView.arrowCursorRects = pronunciationButtons.values.map { textView.convert($0.bounds, from: $0) }
    }

    private func rebuildActions(for result: TranslationServiceResult) {
        if !showsPronunciation(for: result) { stopPronunciation() }
        for button in pronunciationButtons.values { button.removeFromSuperview() }
        pronunciationButtons.removeAll()
        actions.removeAllArrangedSubviews()
        if showsPronunciation(for: result) {
            for (content, selector) in [
                (SpeechContent.dictionaryUS, #selector(speakAmerican)),
                (.dictionaryUK, #selector(speakBritish))
            ] {
                let label = content == .dictionaryUS ? "美" : "英"
                guard result.dictionaryEntry?.pronunciations.contains(where: { $0.label == label && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true else { continue }
                let button = SpeechToggleButton(label: model.speech.label(for: content), symbolSize: Design.Text.body.size)
                button.target = self
                button.action = selector
                button.translatesAutoresizingMaskIntoConstraints = true
                // 放在正文上方的同级视图，避免NSTextView的文字命中截走按钮点击。
                addSubview(button)
                pronunciationButtons[content] = button
            }
        }
        if result.id == .appleTranslation, result.phase == .skipped, !result.appleMissingLanguages.isEmpty {
            let download = NSButton(title: L10n.text("download"), target: self, action: #selector(downloadAppleLanguages))
            download.bezelStyle = .push
            download.setAccessibilityLabel(L10n.text("downloadAppleTranslationLanguagePacks"))
            actions.addArrangedSubview(download)
        }
        if result.phase == .failure {
            let retry = NSButton(title: L10n.text("retry"), target: self, action: #selector(retryResult))
            retry.controlSize = .small
            retry.bezelStyle = .push
            retry.setAccessibilityLabel(L10n.format("retry2", String(describing: result.title)))
            actions.addArrangedSubview(retry)
        }

    }

    private func attributedText(for result: TranslationServiceResult) -> NSAttributedString {
        switch result.phase {
        case .idle, .loading:
            return NSAttributedString(string: "")
        case .failure:
            return styled(
                result.errorMessage ?? L10n.text("translation.noServiceResult"),
                font: Design.Text.body.nsFont,
                color: .error
            )
        case .cancelled:
            return styled(L10n.text("translation.canceled"), font: Design.Text.body.nsFont, color: .inkSecondary)
        case .skipped:
            return styled(
                "⊖  \(result.errorMessage ?? L10n.text("translation.skipped"))",
                font: Design.Text.body.nsFont,
                color: .inkSecondary
            )
        case .streaming, .success:
            if let entry = result.dictionaryEntry {
                return dictionaryText(entry, translatedText: result.text, provider: result.id)
            }
            return styled(
                result.text,
                font: Design.Text.content.nsFont,
                color: .ink,
                lineSpacing: 6
            )
        }
    }

    private func dictionaryText(
        _ entry: DictionaryEntry,
        translatedText: String,
        provider: TranslationProviderID
    ) -> NSAttributedString {
        let value = NSMutableAttributedString()
        append(entry.headword, to: value, font: Design.Text.headword.nsFont)
        value.addAttribute(StreamingResultTextView.arrowCursorAttribute, value: true, range: NSRange(location: 0, length: value.length))
        if provider == .youdao, !translatedText.isEmpty, translatedText != entry.formattedText {
            beginParagraph(in: value, spacing: Design.Space.xs)
            append(translatedText, to: value, font: Design.Text.content.nsFont)
        }
        if provider != .youdao || model.youdaoShowsPronunciations {
            if provider == .youdao {
                let auxiliaryFont = Design.Text.dictionaryAuxiliary.nsFont
                let rows: [(matchingLabel: String, displayLabel: String, content: SpeechContent)] = [
                    ("美", L10n.text("dictionary.usLabel"), .dictionaryUS),
                    ("英", L10n.text("dictionary.ukLabel"), .dictionaryUK)
                ]
                let indent = Self.pronunciationIndent(labels: rows.map(\.displayLabel), font: auxiliaryFont)
                for row in rows {
                    guard let phone = entry.pronunciations.first(where: { $0.label == row.matchingLabel }),
                          !phone.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    beginParagraph(in: value, spacing: Design.Space.s)
                    let start = value.length
                    append(row.displayLabel + "\t", to: value, font: auxiliaryFont, color: .inkSecondary)
                    append("/" + phone.value + "/", to: value, font: auxiliaryFont, color: .inkSecondary)
                    if result.map(showsPronunciation(for:)) == true {
                        // 用定宽不换行空格预留按钮，不往可复制正文中插入附件字符。
                        let side = Design.Dictionary.pronunciationButtonSize
                        let font = Design.Text.dictionaryAuxiliary.nsFont
                        let spaceWidth = ("\u{00A0}" as NSString).size(withAttributes: [.font: font]).width
                        value.append(NSAttributedString(string: "\u{00A0}", attributes: [.font: font, .kern: Design.Space.xs - spaceWidth]))
                        pronunciationLocations[row.content] = value.length
                        value.append(NSAttributedString(string: "\u{00A0}", attributes: [.font: font, .kern: side - spaceWidth]))
                    }
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.headIndent = indent
                    paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                    paragraph.lineSpacing = Design.Space.xs
                    value.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: start, length: value.length - start))
                }
            } else if !entry.pronunciations.isEmpty {
                beginParagraph(in: value, spacing: Design.Space.m)
                append(entry.pronunciations.map { "\($0.displayLabel)  /\($0.value)/" }.joined(separator: "    "),
                       to: value, font: Design.Text.dictionaryAuxiliary.nsFont, color: .inkSecondary)
            }
        }
        if (provider != .youdao || model.youdaoShowsDefinitions), !entry.labels.isEmpty {
            beginParagraph(in: value, spacing: Design.Space.m)
            append(entry.labels.joined(separator: " · "), to: value,
                   font: Design.Text.dictionaryAuxiliary.nsFont, color: .inkSecondary)
        }
        if provider != .youdao || model.youdaoShowsDefinitions {
            for block in entry.blocks {
                beginParagraph(in: value, spacing: Design.Space.m)
                if let parts = partOfSpeech(in: block.text) {
                    let indent = (parts.prefix as NSString).size(withAttributes: [.font: Design.Text.dictionaryAuxiliary.nsFont]).width + Design.Space.s
                    let start = value.length
                    append(parts.prefix + "\t", to: value, font: Design.Text.dictionaryAuxiliary.nsFont, color: .inkSecondary)
                    append(parts.meaning, to: value, font: Design.Text.content.nsFont)
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.headIndent = indent
                    paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                    paragraph.lineSpacing = Design.Space.xs
                    value.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: start, length: value.length - start))
                } else {
                    append(block.text, to: value, font: Design.Text.content.nsFont)
                }
            }
            if !entry.forms.isEmpty {
                beginParagraph(in: value, spacing: Design.Space.m)
                let font = Design.Text.dictionaryAuxiliary.nsFont
                let separator = "    "
                let gap = (separator as NSString).size(withAttributes: [.font: font]).width
                let availableWidth = measuredWidth > 0 ? measuredWidth : CGFloat.greatestFiniteMagnitude
                var lineWidth: CGFloat = 0
                for form in entry.forms {
                    let item = NSMutableAttributedString(attributedString: styled(form.label + "：", font: font, color: .inkSecondary))
                    item.append(styled(form.value, font: Design.Text.body.nsFont, color: .link))
                    let itemWidth = ceil(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(item), nil, nil, nil))
                    if lineWidth > 0 {
                        if lineWidth + gap + itemWidth > availableWidth {
                            append("\n", to: value, font: font)
                            lineWidth = 0
                        } else {
                            append(separator, to: value, font: font)
                            lineWidth += gap
                        }
                    }
                    append(form.label + "：", to: value, font: Design.Text.dictionaryAuxiliary.nsFont, color: .inkSecondary)
                    appendTerm(form.value, to: value, font: Design.Text.body.nsFont)
                    lineWidth += itemWidth
                }
            }
        }
        if (provider != .youdao || model.youdaoShowsPhrases), !entry.phrases.isEmpty {
            for (index, phrase) in entry.phrases.enumerated() {
                beginParagraph(in: value, spacing: index == 0 ? Design.Space.m : Design.Space.xs)
                appendTerm(phrase.title, to: value, font: Design.Text.body.nsFont)
                append("  " + phrase.meanings.joined(separator: "；"), to: value,
                       font: Design.Text.body.nsFont, color: .ink)
            }
        }
        if (provider != .youdao || model.youdaoShowsExamples), !entry.examples.isEmpty {
            beginParagraph(in: value, spacing: Design.Space.m)
            append(L10n.text("bilingualExamples"), to: value, font: Design.Text.dictionaryAuxiliary.nsFont, color: .inkSecondary)
            for (index, example) in entry.examples.enumerated() {
                if index > 0 {
                    let previous = (value.string as NSString).paragraphRange(for: NSRange(location: value.length-1, length: 0))
                    value.addAttribute(Self.paragraphGap, value: Design.Space.s, range: previous)
                }
                beginParagraph(in: value, spacing: index == 0 ? Design.Space.xs : Design.Space.s)
                let start = value.length
                append("·\t" + example.source + "\n" + example.translation, to: value,
                       font: Design.Text.dictionaryExample.nsFont, color: .ink)
                let paragraph = NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent = 0
                paragraph.headIndent = Design.Space.m
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: Design.Space.m)]
                paragraph.lineSpacing = Design.Space.xs
                value.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: start, length: value.length - start))
                let translation = NSRange(location: start + ("·\t" + example.source + "\n" as NSString).length, length: (example.translation as NSString).length)
                let translatedParagraph = paragraph.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                translatedParagraph.firstLineHeadIndent = Design.Space.m
                value.addAttribute(.paragraphStyle, value: translatedParagraph, range: translation)
            }
        }
        return value
    }

    private func beginParagraph(in value: NSMutableAttributedString, spacing: CGFloat) {
        guard value.length > 0 else { return }
        let previous = (value.string as NSString).paragraphRange(for: NSRange(location: value.length - 1, length: 0))
        let paragraph = (value.attribute(.paragraphStyle, at: value.length - 1, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        paragraph.paragraphSpacing = spacing
        value.addAttribute(.paragraphStyle, value: paragraph, range: previous)
        value.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
    }

    private func partOfSpeech(in text: String) -> (prefix: String, meaning: String)? {
        guard let range = text.range(of: #"^(?:[A-Za-z]+\.(?:\s*&\s*[A-Za-z]+\.)?|【[^】]+】)\s+"#, options: .regularExpression) else { return nil }
        return (String(text[range]).trimmingCharacters(in: .whitespaces), String(text[range.upperBound...]))
    }

    private func styled(
        _ text: String,
        font: NSFont,
        color: ThemeToken,
        lineSpacing: CGFloat = 3
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        return NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: palette[color], StreamingResultTextView.themeTokenAttribute: color.rawValue, .paragraphStyle: paragraph]
        )
    }

    private func append(
        _ text: String,
        to value: NSMutableAttributedString,
        font: NSFont,
        color: ThemeToken = .ink
    ) {
        value.append(styled(text, font: font, color: color))
    }

    private func appendTerm(_ term: String, to value: NSMutableAttributedString, font: NSFont, color: ThemeToken = .link) {
        let text = NSMutableAttributedString(attributedString: styled(term, font: font, color: color))
        if text.length > 0 {
            let token = "seven-term:\(dictionaryTerms.count)"
            dictionaryTerms[token] = term
            text.addAttribute(.link, value: token, range: NSRange(location: 0, length: text.length))
        }
        value.append(text)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard !renderingSuspended, textView === self.textView || textView.isDescendant(of: self.textView),
              let storage = textView.textStorage, (0..<storage.length).contains(charIndex) else { return true }
        let displayedLink = storage.attribute(.link, at: charIndex, effectiveRange: nil)
        if textView === self.textView, let token = link as? String, displayedLink as? String == token, let term = dictionaryTerms[token] {
            model.translateTerm(term)
        } else if model.rendersCustomResultsAsMarkdown, isShowingRichMarkdown,
                  let url = link as? URL, displayedLink as? URL == url, let window {
            ResultMarkdownLink.confirm(url, in: window)
        }
        return true
    }

    static func pronunciationIndent(labels: [String], font: NSFont) -> CGFloat {
        let labelWidth = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return max(Design.Dictionary.pronunciationIndent, labelWidth + Design.Space.s)
    }

    private func showsPronunciation(for result: TranslationServiceResult) -> Bool {
        result.id == .youdao && result.phase == .success && model.youdaoShowsPronunciations
            && result.dictionaryEntry?.headword.isEmpty == false
            && result.dictionaryEntry?.pronunciations.contains { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
    }

    private func stopPronunciation() {
        guard result?.id == .youdao else { return }
        if model.speech.isActive(.dictionaryUS) || model.speech.isActive(.dictionaryUK) { model.speech.stop() }
    }

    private func updatePronunciationButtons() {
        guard let word = result?.dictionaryEntry?.headword else { return }
        for (content, button) in pronunciationButtons {
            let language = content == .dictionaryUS ? "en-US" : "en-GB"
            button.isEnabled = model.speech.canSpeak(text: word, declaredLanguage: language)
            button.apply(model.speech.appearance(for: content), symbol: model.speech.icon(for: content),
                         label: model.speech.availabilityLabel(content: content, text: word, declaredLanguage: language))
        }
    }

    private func speakPronunciation(_ content: SpeechContent, language: String) {
        guard !renderingSuspended, let result, showsPronunciation(for: result),
              let word = result.dictionaryEntry?.headword else { return }
        model.speech.toggle(content: content, text: word, declaredLanguage: language)
        updatePronunciationButtons()
    }

    @objc private func speakAmerican() { speakPronunciation(.dictionaryUS, language: "en-US") }
    @objc private func speakBritish() { speakPronunciation(.dictionaryUK, language: "en-GB") }

    @objc private func downloadAppleLanguages() { model.downloadAppleLanguagePacks() }

    @objc private func retryResult() {
        guard let result else { return }
        model.retryResult(result.id)
    }

}
