import AppKit

extension TranslationModel {
    // MARK: 原文语言识别

    /// 原文一变就重新检测，语言栏与交换永远对应当前这段原文。
    /// 原文改变时取消进行中的识别，停止输入 `languageDetectionDelay` 后再识别。
    internal func inputDidChange() {
        localDetectionCache = nil
        pendingHistory = nil
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


    /// 这段原文的语言：联网确认过则用确认结果，否则用系统离线识别。
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

    /// 本次请求用于判断与路由的源语言：手动指定的语言，或自动识别的结果（识别不出时为 auto）。
    internal func effectiveSource(for text: String) -> String {
        requestSource == LanguageCatalog.automatic
            ? (detectedLanguage(for: text) ?? LanguageCatalog.automatic)
            : requestSource
    }

    /// 可信语言由 LanguageDetectionPolicy 集中判断；其余结果按设置交给所选服务优化。
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

    /// 原文语言供朗读使用：仍在等待联网识别时返回 nil 并标记为识别中，避免用误判的语言嗓音朗读。
    var isSourceLanguagePending: Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && needsOnlineDetection(for: text)
    }

    /// 朗读原文时声明的语言：手动指定的语言，或已确定的识别结果。
    var sourceLanguageForSpeech: String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requestSource == LanguageCatalog.automatic else { return requestSource }
        return text.isEmpty ? nil : detectedLanguage(for: text)
    }

    /// 用户偏好变化会改变本机候选排序，作废旧缓存和旧任务，避免各入口沿用不同结果。
    internal func preferredDetectionLanguagesDidChange() {
        confirmedDetection = nil
        localDetectionCache = nil
        detectionTask?.cancel(); detectionTask = nil
        detectingText = nil; isDetectingOnline = false
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        detectedSource = text.isEmpty ? nil : detectedLanguage(for: text)
        if !text.isEmpty { scheduleDetection(of: text, after: .zero) }
    }

    /// 测试用：等待当前识别结束。
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

    /// 识别一段原文并更新语言栏；需要时仅请求所选联网服务，失败时采用本机结果。
    private func runDetection(of text: String) async {
        guard input.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
        if needsOnlineDetection(for: text) {
            isDetectingOnline = true
            let local = localLanguageDetection(for: text)
            let order = languageDetectionMode.onlineOrder.compactMap { mode in languageDetectors[mode].map { (mode, $0) } }
            let start = Date()
            var result: (mode: LanguageDetectionMode, code: String?)?
            for (mode, detector) in order {
                // 原文改变或识别方式切换后，不再发送这段原文。
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
            // 先复位，避免 translate() 开头的 cancel() 把识别当作翻译记为“已取消”。
            isLoading = false
            translate()
        } else {
            let providers = retryAfterDetection
            retryAfterDetection = []
            providers.forEach(retryResult)
            settleLoadingAfterDetection()
        }
    }

    /// 识别结束后按实际在跑的请求重算加载状态：等待中的服务可能已被停用，一个请求也没有启动。
    private func settleLoadingAfterDetection() {
        if let generation {
            refreshOverallState(generation: generation)
            return
        }
        let running = serviceResults.contains { $0.phase.isRunning }
        isLoading = running
        if !running, status == "正在识别语言…" { status = "准备好，开始一段翻译。" }
    }

    /// 切换识别方式：作废进行中的识别与已确认结果，按新方式立即重新识别当前原文。
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
