import AppKit

extension TranslationModel {
    // MARK: Source Language Detection

    /// Re-detects whenever source text changes so the language bar and swap always match the current input.
    /// Cancels in-flight detection on source text changes and detects after `languageDetectionDelay` of idle input.
    internal func inputDidChange() {
        localDetectionCache = nil
        historyRound = nil
        translateAfterDetection = false
        retryAfterDetection = []
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            detectionTask?.cancel()
            detectionTask = nil
            detectingText = nil
            isDetectingOnline = false
            detectedSource = nil
            return
        }
        scheduleDetection(of: text, after: languageDetectionDelay)
    }


    /// Language of this source text: uses the online-confirmed result if available, otherwise falls back to offline system detection.
    func detectedLanguage(for text: String) -> String? {
        if let confirmedDetection, confirmedDetection.text == text { return confirmedDetection.code }
        return localLanguageDetection(for: text).code
    }

    private func localLanguageDetection(for text: String) -> LocalLanguageDetection {
        if let cached = localDetectionCache, cached.text == text,
           cached.primary == primaryLanguage, cached.secondary == secondaryLanguage {
            return cached.result
        }
        let result = LanguageCatalog.localDetection(for: text, primary: primaryLanguage, secondary: secondaryLanguage)
        if text == input.trimmingCharacters(in: .whitespacesAndNewlines) {
            localDetectionCache = (text, primaryLanguage, secondaryLanguage, result)
        }
        return result
    }

    /// Source language used for decisions and routing in this request: manually chosen language or auto-detected result (auto if undetermined).
    internal func effectiveSource(for text: String) -> String {
        requestSource == LanguageCatalog.automatic
            ? (detectedLanguage(for: text) ?? LanguageCatalog.automatic)
            : requestSource
    }

    /// Trusted languages are determined centrally by LanguageDetectionPolicy; remaining results are refined by the configured service.
    internal func needsOnlineDetection(for text: String) -> Bool {
        guard languageDetectionMode != .system,
              requestSource == LanguageCatalog.automatic,
              confirmedDetection?.text != text else { return false }
        return LanguageDetectionPolicy.needsOnlineCheck(
            local: localLanguageDetection(for: text),
            primary: primaryLanguage,
            secondary: secondaryLanguage
        )
    }

    /// Source language for speech: returns nil and marks detection as pending while awaiting online detection to avoid speaking with the wrong voice.
    var isSourceLanguagePending: Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && needsOnlineDetection(for: text)
    }

    /// Declared language when speaking source text: either the manually selected language or the resolved detection result.
    var sourceLanguageForSpeech: String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requestSource == LanguageCatalog.automatic else { return requestSource }
        return text.isEmpty ? nil : detectedLanguage(for: text)
    }

    /// User preference changes alter local candidate ranking; invalidate stale caches and tasks so all entry points stay consistent.
    internal func preferredDetectionLanguagesDidChange() {
        confirmedDetection = nil
        localDetectionCache = nil
        detectionTask?.cancel(); detectionTask = nil
        detectingText = nil; isDetectingOnline = false
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        detectedSource = text.isEmpty ? nil : detectedLanguage(for: text)
        if !text.isEmpty { scheduleDetection(of: text, after: .zero) }
    }

    /// For testing: waits for the current detection to finish.
    func waitForLanguageDetection() async {
        await detectionTask?.value
    }

    internal func scheduleDetection(of text: String, after delay: Duration) {
        detectionTask?.cancel()
        detectingText = text
        isDetectingOnline = false
        detectionTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.runDetection(of: text)
        }
    }

    /// Detects source text language and updates the language bar; queries only the selected online service when needed, falling back to local results on failure.
    private func runDetection(of text: String) async {
        guard input.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
        if needsOnlineDetection(for: text) {
            isDetectingOnline = true
            let local = localLanguageDetection(for: text)
            let order = languageDetectionMode.onlineOrder.compactMap { mode in languageDetectors[mode].map { (mode, $0) } }
            let start = Date()
            var result: (mode: LanguageDetectionMode, code: String?)?
            for (mode, detector) in order {
                // Do not send this source text if it changed or the detection mode switched.
                guard !Task.isCancelled else { return }
                do {
                    result = (mode, try await detector.detect(text))
                    break
                } catch {
                    if Task.isCancelled { return }
                    let reason = String(describing: type(of: error))
                    Task { [logger] in
                        await logger.record(.warning, "language_detection_failed", metadata: [
                            "host": mode.host ?? "", "reason": reason
                        ])
                    }
                }
            }
            guard !Task.isCancelled, input.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            let code: String?
            if let detected = result?.code, LanguageCatalog.isChinese(detected) {
                code = LocalLanguageDetector.chineseVariant(of: text, primary: primaryLanguage, secondary: secondaryLanguage)
            } else {
                code = result?.code ?? local.code
            }
            confirmedDetection = (text, code)
            let metadata = [
                "host": result?.mode.host ?? "system",
                "language": code ?? "unknown",
                "characters": String(text.count),
                "elapsed_ms": String(Int(Date().timeIntervalSince(start) * 1_000))
            ]
            Task { [logger] in await logger.record(.info, "language_detected", metadata: metadata) }
        }
        detectedSource = detectedLanguage(for: text)
        detectingText = nil
        isDetectingOnline = false
        detectionTask = nil
        if translateAfterDetection {
            translateAfterDetection = false
            retryAfterDetection = []
            // Reset first so cancel() at the start of translate() does not record detection as a cancelled translation.
            isLoading = false
            translate()
        } else {
            let providers = retryAfterDetection
            retryAfterDetection = []
            providers.forEach(retryResult)
            settleLoadingAfterDetection()
        }
    }

    /// Recomputes loading state from actually running requests after detection finishes: queued services may have been disabled so none started.
    private func settleLoadingAfterDetection() {
        if let generation {
            refreshOverallState(generation: generation)
            return
        }
        let running = serviceResults.contains { $0.phase.isRunning }
        isLoading = running
        if !running, status == "正在识别语言…" { status = "准备好，开始一段翻译。" }
    }

    /// Switches detection mode: invalidates in-flight detection and confirmed results, then immediately re-detects the current source text.
    internal func languageDetectionModeDidChange(from oldValue: LanguageDetectionMode) {
        guard languageDetectionMode != oldValue else { return }
        detectionTask?.cancel()
        detectionTask = nil
        detectingText = nil
        isDetectingOnline = false
        confirmedDetection = nil
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        scheduleDetection(of: text, after: .zero)
    }
}
