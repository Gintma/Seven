import AppKit

extension TranslationModel {
    // MARK: Language Bar Selection & Swap

    /// Remaining languages outside pinned common languages, shown in catalog order under "More Languages" in the menu.
    var otherLanguages: [String] {
        LanguageCatalog.codes.filter { !commonLanguages.contains($0) }
    }

    var automaticTargetTitle: String { L10n.format("auto2", String(describing: LanguageCatalog.name(primaryLanguage)), String(describing: LanguageCatalog.name(secondaryLanguage))) }

    /// Source language for this request: either a fixed language or auto-detect.
    var requestSource: String {
        source
    }

    /// Effective source language displayed in the language bar; nil when set to auto and undetermined.
    var displaySource: String? {
        requestSource == LanguageCatalog.automatic ? detectedSource : requestSource
    }

    /// Effective target language displayed in the language bar; nil when there is no source text and target is auto.
    var displayTarget: String? {
        guard target == Self.automaticTarget else { return target }
        guard hasInputText else { return nil }
        guard let from = displaySource else { return primaryLanguage }
        return LanguageRouting.resolvedTarget(
            for: "", source: from, target: target, primary: primaryLanguage, secondary: secondaryLanguage
        )
    }

    func setSource(_ code: String) {
        guard code != source else { return }
        // Source language changed, so stale online detection must not write back; normal translation cancellation preserves the detection task.
        detectionTask?.cancel()
        detectionTask = nil
        detectingText = nil
        isDetectingOnline = false
        source = code
        languageDidChange()
    }

    func setTarget(_ code: String) {
        guard code != target else { return }
        target = code
        languageDidChange()
    }

    /// Result used as the new source text on swap: the topmost successful translation result.
    var swapCandidate: TranslationServiceResult? {
        serviceResults.first { $0.isTranslation && instance($0.id)?.mode != .custom && $0.phase == .success && !$0.text.isEmpty }
    }

    var canSwapLanguages: Bool {
        if swapCandidate != nil { return swappedLanguages() != nil }
        return source != LanguageCatalog.automatic && target != Self.automaticTarget
    }

    var swapTitle: String {
        swapCandidate.map { L10n.format("swapWithTheTranslationFrom", String(describing: $0.title)) } ?? L10n.text("swapLanguages")
    }

    /// Swapped source and target languages: any auto side stays auto, while a fixed side adopts the other side's effective language.
    private func swappedLanguages() -> (source: String, target: String)? {
        // Evaluate live from the current source text instead of the debounced display value in the language bar.
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSource = requestSource == LanguageCatalog.automatic
            ? (text.isEmpty ? nil : detectedLanguage(for: text)) : requestSource
        let currentTarget: String? = target != Self.automaticTarget ? target : (text.isEmpty ? nil : LanguageRouting.resolvedTarget(
            for: "", source: currentSource ?? LanguageCatalog.automatic, target: target,
            primary: primaryLanguage, secondary: secondaryLanguage
        ))
        let newSource = source == LanguageCatalog.automatic ? LanguageCatalog.automatic : currentTarget
        let newTarget = target == Self.automaticTarget ? Self.automaticTarget : currentSource
        guard let newSource, let newTarget else { return nil }
        return (newSource, newTarget)
    }

    func swapLanguages() {
        guard canSwapLanguages, let swapped = swappedLanguages() else { return }
        let replacement = swapCandidate?.text
        source = swapped.source
        target = swapped.target
        if let replacement {
            input = replacement
        }
        languageDidChange()
    }

    /// Immediately re-translates on language change if source text is present.
    private func languageDidChange() {
        if hasInputText {
            translate()
        } else {
            editOccurred()
        }
    }
}
