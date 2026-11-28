import AppKit

extension TranslationModel {
    // MARK: Input Preparation & UI Actions

    /// An isolated in-place replacement session queries a single enabled, non-paused translation service without modifying service toggles.
    func beginInputReplacement(_ text: String) throws -> TranslationProviderID {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InputReplacementError.empty }
        guard text.count <= 20_000 else { throw InputReplacementError.tooLong }
        prepareSelectedText(text)
        let available = visibleServices()
        guard let placeholder = available.first(where: { $0.isTranslation && instance($0.id)?.mode == .translate && isServiceExpanded($0.id) }) else {
            throw InputReplacementError.noService
        }
        serviceResults = [placeholder]
        retryResult(placeholder.id)
        return placeholder.id
    }

    /// Returns whether content was actually copied so the button can show confirmation feedback.
    @discardableResult
    func copyResult(_ provider: TranslationProviderID) -> Bool {
        guard let value = serviceResults.first(where: { $0.id == provider })?.text, !value.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        status = "结果已复制"
        return true
    }

    func editOccurred() {
        speech.stop()
        cancel()
        historyRound = nil
        serviceResults = []
        issue = nil
        recoveryAction = nil
        resolvedTarget = nil
        status = "准备好，开始一段翻译。"
    }

    func updateInput(_ value: String) {
        guard value != input else { return }
        input = value
        editOccurred()
    }

    func beginClearTransition() {
        speech.stop()
        cancel()
        input = ""
        historyRound = nil
        issue = nil
        recoveryAction = nil
        resolvedTarget = nil
        status = "准备好，开始一段翻译。"
    }

    func finishClearTransition() {
        guard input.isEmpty else { return }
        serviceResults = []
    }

    func clear() {
        beginClearTransition()
        finishClearTransition()
    }

    func clearPanelContentIfEnabled() {
        if clearTranslationOnDismiss { clear() }
    }

    func translateTerm(_ value: String) {
        let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= 20_000 else { return }
        if term == input {
            editOccurred()
        } else {
            updateInput(term)
        }
        translate()
    }

    func prepareSelectedText(_ value: String) {
        speech.stop()
        cancel()
        input = value
        historyRound = nil
        serviceResults = []
        issue = nil
        recoveryAction = nil
        resolvedTarget = target == Self.automaticTarget
            ? LanguageRouting.resolvedTarget(for: value, source: effectiveSource(for: value), target: target, primary: primaryLanguage, secondary: secondaryLanguage)
            : target
        status = "已读取选中文字"
    }

    func presentSelectionError(_ error: SelectionReadError) {
        speech.stop()
        cancel()
        historyRound = nil
        serviceResults = []
        issue = .forError(error)
        recoveryAction = nil
        status = "划词翻译未完成"
    }

    func prepareScreenshotText(_ value: String, needsReview: Bool = false) {
        prepareSelectedText(value)
        status = needsReview
            ? "识别质量较低，请校对后按 Enter 翻译"
            : "已识别截图文字 · \(value.count) 字符"
    }

    func presentScreenshotError(_ error: ScreenshotTranslationError) {
        speech.stop()
        cancel()
        historyRound = nil
        serviceResults = []
        issue = .forError(error)
        recoveryAction = nil
        status = "截图翻译未完成"
    }

    var canRetryGlobalIssue: Bool {
        hasInputText && issue == Self.noServicesIssue
    }

    var recoveryTitle: String? {
        recoveryAction == .serviceSettings ? L10n.text("serviceSettings") : nil
    }

    func performRecovery() {
        if recoveryAction == .serviceSettings { openSettings() }
    }

    func hide() { speech.stop(); cancel(); onHide?() }
    func openSettings() { onOpenSettings?() }
    func openHistory() { onOpenHistory?() }
    func startScreenshot() { onStartScreenshot?() }

    var hasInputText: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @discardableResult
    func copyInput() -> Bool {
        guard !input.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(input, forType: .string)
        status = "识别文字已复制"
        return true
    }
}
