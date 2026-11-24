import AppKit

extension TranslationModel {
    // MARK: 语言栏选择与交换

    /// 不在常用语言里的其余语言，按语言目录顺序，显示在菜单的“更多语言”中。
    var otherLanguages: [String] {
        LanguageCatalog.codes.filter { !commonLanguages.contains($0) }
    }

    var automaticTargetTitle: String { L10n.format("auto2", String(describing: LanguageCatalog.name(primaryLanguage)), String(describing: LanguageCatalog.name(secondaryLanguage))) }

    /// 本次请求的源语言：固定语言或自动检测。
    var requestSource: String {
        source
    }

    /// 语言栏显示用的实际源语言；自动且检测不出时为 nil。
    var displaySource: String? {
        requestSource == LanguageCatalog.automatic ? detectedSource : requestSource
    }

    /// 语言栏显示用的实际目标语言；没有原文且目标为自动时为 nil。
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
        // 源语言已改变，旧联网识别不得继续写回；普通取消翻译仍保留识别任务。
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

    /// 交换时用作新原文的结果：排在最上面的、成功的翻译结果。
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

    /// 交换后的源语言与目标语言：自动的一方保持自动，固定的一方换成另一方的实际语言。
    private func swappedLanguages() -> (source: String, target: String)? {
        // 按当前原文实时判断，不用语言栏上延迟更新的显示值。
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

    /// 语言改变后：有原文就立即重新翻译。
    private func languageDidChange() {
        if hasInputText {
            translate()
        } else {
            editOccurred()
        }
    }
}
