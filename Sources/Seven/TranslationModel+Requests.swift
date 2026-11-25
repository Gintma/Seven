import AppKit

extension TranslationModel {
    // MARK: 翻译请求与结果生命周期

    func translate() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= 20_000 else { issue = .key("translationInputTooLong"); return }
        speech.stop()
        cancel()
        historyRound = nil
        if needsOnlineDetection(for: text) {
            // 识别完成后再翻译；同一段原文正在联网识别时不重复请求。
            translateAfterDetection = true
            isLoading = true
            status = "正在识别语言…"
            if !(detectingText == text && isDetectingOnline) { scheduleDetection(of: text, after: .zero) }
            return
        }
        detectedSource = detectedLanguage(for: text)
        let requestLanguages = beginRequestLanguages(for: text)
        let requestTarget = requestLanguages.target

        let id = UUID()
        var results: [TranslationServiceResult] = []
        var startedProviders: Set<TranslationProviderID> = []
        var compatibleRequests: [TranslationProviderID: TranslationRequest] = [:]
        for placeholder in visibleServices() {
            var result = placeholder
            if !isServiceExpanded(result.id) {
                result.phase = .skipped
                result.issue = Self.pausedServiceIssue
            } else if result.id == .ecdict, !dictionaryApplies(to: text) {
                result.phase = .skipped
                result.issue = Self.dictionaryInputIssue
            } else if let message = unsupportedLanguageMessage(result, text: text, target: requestTarget) {
                result.phase = .skipped
                result.issue = message
            } else if !result.id.isBuiltIn {
                do {
                    compatibleRequests[result.id] = try makeCompatibleRequest(provider: result.id, text: text, target: requestTarget)
                    result.phase = .loading
                    startedProviders.insert(result.id)
                } catch {
                    result.phase = .failure
                    result.issue = .forError(error)
                }
            } else {
                result.phase = .loading
                startedProviders.insert(result.id)
            }
            results.append(result)
        }

        guard !results.isEmpty else {
            issue = Self.noServicesIssue
            recoveryAction = .serviceSettings
            status = "检查服务设置后重试。"
            return
        }

        generation = id
        serviceResults = results
        let runningResults = results.filter { $0.phase.isRunning }
        if !runningResults.isEmpty {
            historyRound = HistoryRound(
                sourceText: text, sourceLanguage: requestLanguages.source, targetLanguage: requestTarget
            )
        }
        primaryResultID = runningResults.first(where: \.isTranslation)?.id ?? runningResults.first?.id
        isLoading = !runningResults.isEmpty
        issue = nil; recoveryAction = nil
        status = isLoading ? "正在获取 \(runningResults.count) 项结果…" : "翻译未完成"
        Task { await logger.record(.info, "translation_started", metadata: [
            "characters": String(text.count)
        ]) }

        for provider in serviceInstances.map(\.id) where startedProviders.contains(provider) {
            startService(
                provider,
                text: text,
                target: requestTarget,
                generation: id,
                compatibleRequest: compatibleRequests[provider]
            )
        }

        refreshOverallState(generation: id)
    }

    func retryResult(_ provider: TranslationProviderID) {
        guard let index = resultIndex(provider) else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 20_000 else { return }

        speech.stop()
        // 与 translate() 共用识别等待：识别完成后只启动这个服务，不重启全部服务。
        if needsOnlineDetection(for: text) {
            if !retryAfterDetection.contains(provider) { retryAfterDetection.append(provider) }
            serviceResults[index].phase = .loading
            serviceResults[index].issue = nil
            isLoading = true
            status = "正在识别语言…"
            if !(detectingText == text && isDetectingOnline) { scheduleDetection(of: text, after: .zero) }
            return
        }
        let requestLanguages = beginRequestLanguages(for: text)
        let requestTarget = requestLanguages.target

        let id = generation ?? UUID()
        generation = id
        serviceTasks[provider]?.cancel()
        serviceTasks[provider] = nil
        if provider == .appleTranslation { appleTranslationRequest = nil }
        if let message = unsupportedLanguageMessage(serviceResults[index], text: text, target: requestTarget) {
            serviceResults[index].phase = .skipped
            serviceResults[index].text = ""
            serviceResults[index].dictionaryEntry = nil
            serviceResults[index].issue = message
            refreshOverallState(generation: id)
            return
        }
        serviceResults[index].appleMissingLanguages = []
        serviceResults[index].phase = .loading
        serviceResults[index].text = ""
        serviceResults[index].dictionaryEntry = nil
        serviceResults[index].issue = nil
        isLoading = true
        issue = nil
        recoveryAction = nil
        if primaryResultID == nil, serviceResults[index].isTranslation {
            primaryResultID = provider
        }
        status = "正在重新获取\(serviceResults[index].title)…"

        var compatibleRequest: TranslationRequest?
        switch provider {
        case .ecdict:
            guard dictionaryService.isAvailable, dictionaryApplies(to: text) else {
                serviceResults[index].phase = .skipped
                serviceResults[index].issue = Self.dictionaryInputIssue
                refreshOverallState(generation: id)
                return
            }
        case .appleTranslation:
            guard systemTranslationBridgeAvailable else {
                failResult(
                    provider,
                    error: TranslationError.configuration(.key("appleTranslationIsCurrentlyUnavailable")),
                    generation: id
                )
                return
            }
        case .youdao, .google:
            break
        default:
            do {
                compatibleRequest = try makeCompatibleRequest(provider: provider, text: text, target: requestTarget)
            } catch {
                failResult(provider, error: error, generation: id)
                return
            }
        }
        if historyRound == nil {
            historyRound = HistoryRound(
                sourceText: text, sourceLanguage: requestLanguages.source, targetLanguage: requestTarget
            )
        }
        startService(
            provider,
            text: text,
            target: requestTarget,
            generation: id,
            compatibleRequest: compatibleRequest
        )

        Task { await logger.record(.info, "translation_retry_started", metadata: [
            "characters": String(text.count)
        ]) }
        refreshOverallState(generation: id)
    }

    /// 英汉词典只查英文：原文不是单词或短语，或源语言已知（手动选择或检测得出）且不是英语时跳过。
    private func dictionaryApplies(to text: String) -> Bool {
        guard ECDictionaryService.normalizedQuery(text) != nil else { return false }
        let source = requestSource == LanguageCatalog.automatic ? detectedLanguage(for: text) : requestSource
        return source == nil || source == "en"
    }

    /// 计算本次请求的源语和目标语，并同步浮窗的目标语。
    private func beginRequestLanguages(for text: String) -> (source: String, target: String) {
        let source = effectiveSource(for: text)
        let requestTarget = LanguageRouting.resolvedTarget(
            for: text,
            source: source,
            target: target,
            primary: primaryLanguage,
            secondary: secondaryLanguage
        )
        resolvedTarget = requestTarget
        return (source, requestTarget)
    }

    /// 该服务不支持本次源语言或目标语言时的说明（显示为灰色“已跳过”，不发请求）；只在翻译模式下判断。
    private func unsupportedLanguageMessage(
        _ result: TranslationServiceResult,
        text: String,
        target requestTarget: String
    ) -> LocalizedMessage? {
        let source: String
        if result.id == .appleTranslation {
            source = appleTranslationSource(for: text, target: requestTarget)
        } else {
            source = effectiveSource(for: text)
        }
        guard let code = ServiceLanguageSupport.unsupportedLanguage(result.id, source: source, target: requestTarget) else {
            return nil
        }
        let provider = instance(result.id)?.provider
        let service: LocalizedMessage.Argument = if let provider, provider.isBuiltIn { .provider(provider) } else { .text(result.title) }
        return .key("translation.unsupportedLanguage", service, .language(code))
    }

    /// Apple 翻译需要明确的源语言；检测失败时取语言对中的另一端。
    private func appleTranslationSource(for text: String, target requestTarget: String) -> String {
        guard requestSource == LanguageCatalog.automatic else { return requestSource }
        return detectedLanguage(for: text) ?? (requestTarget == primaryLanguage ? secondaryLanguage : primaryLanguage)
    }

    private func makeCompatibleRequest(provider: TranslationProviderID, text: String, target requestTarget: String) throws -> TranslationRequest {
        guard let configuration = instance(provider)?.configuration else {
            throw TranslationError.configuration("自备密钥服务尚未配置。")
        }
        _ = try configuration.validatedURL()
        let key = try resolvedCredential(for: configuration)
        if instance(provider)?.provider != .custom, key.isEmpty { throw TranslationError.configuration(.key("enterAnAPIKey")) }
        return TranslationRequest(text: text, source: requestSource, target: requestTarget, configuration: configuration, apiKey: key, firstLanguage: primaryLanguage)
    }

    /// 启动单个服务。调用方负责事先检查可用性；自备密钥服务需传入已准备好的请求。
    private func startService(
        _ provider: TranslationProviderID,
        text: String,
        target requestTarget: String,
        generation id: UUID,
        compatibleRequest: TranslationRequest?
    ) {
        switch provider {
        case .ecdict:
            serviceTasks[.ecdict] = Task { [weak self, dictionaryService] in
                let outcome: Result<DictionaryEntry?, Error>
                do {
                    outcome = .success(try await dictionaryService.lookup(text))
                } catch {
                    outcome = .failure(error)
                }
                guard let self, !Task.isCancelled else { return }
                self.finishDictionary(outcome, generation: id)
            }

        case .appleTranslation:
            let source = appleTranslationSource(for: text, target: requestTarget)
            let request = AppleTranslationRequest(id: UUID(), generation: id, text: text,
                sourceIdentifier: Self.localeIdentifier(for: source), targetIdentifier: Self.localeIdentifier(for: requestTarget) ?? "zh-Hans")
            serviceTasks[provider]?.cancel()
            appleTranslationRequest = nil
            serviceTasks[provider] = Task { [weak self, appleAvailability] in
                let availability = await appleAvailability.availability(source: source, target: requestTarget)
                guard let self, !Task.isCancelled, self.generation == id else { return }
                self.serviceTasks[provider] = nil
                if case .requiresDownload(let missing) = availability, let index = self.resultIndex(provider) {
                    self.serviceResults[index].phase = .skipped
                    self.serviceResults[index].appleMissingLanguages = missing.isEmpty ? [source, requestTarget] : missing
                    let languages = self.serviceResults[index].appleMissingLanguages
                    self.serviceResults[index].issue = .key("downloadTheLanguagePacksToUseApple", .languages(languages))
                    self.refreshOverallState(generation: id)
                } else { self.appleTranslationRequest = request }
            }

        case .youdao, .google:
            startOnlineTranslation(
                provider,
                service: provider == .youdao ? youdaoService : googleService,
                request: .init(text: text, source: requestSource, target: requestTarget),
                generation: id
            )

        default:
            guard let compatibleRequest else { return }
            startCompatibleTranslation(provider, request: compatibleRequest, generation: id)
        }
    }

    func cancel() {
        // 只取消“识别后自动翻译 / 启动服务”，识别本身照常完成，用于更新语言栏。
        translateAfterDetection = false
        retryAfterDetection = []
        generation = nil
        serviceTasks.values.forEach { $0.cancel() }
        serviceTasks.removeAll()
        appleTranslationRequest = nil
        if isLoading {
            status = "已取消，可以重新翻译。"
            Task { await logger.record(.info, "translation_cancelled", metadata: [:]) }
        }
        for index in serviceResults.indices where serviceResults[index].phase.isRunning {
            serviceResults[index].phase = serviceResults[index].text.isEmpty ? .cancelled : .success
        }
        isLoading = false
    }

    func downloadAppleLanguagePacks() {
        guard let index = resultIndex(.appleTranslation), !serviceResults[index].appleMissingLanguages.isEmpty else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let id = generation ?? UUID()
        generation = id
        let target = beginRequestLanguages(for: text).target
        serviceResults[index].phase = .loading
        serviceResults[index].issue = nil
        isLoading = true
        appleTranslationRequest = AppleTranslationRequest(id: UUID(), generation: id, text: text,
            sourceIdentifier: Self.localeIdentifier(for: appleTranslationSource(for: text, target: target)),
            targetIdentifier: Self.localeIdentifier(for: target) ?? "zh-Hans", prepareOnly: true)
    }

    func completeApplePreparation(_ request: AppleTranslationRequest) {
        guard appleTranslationRequest?.id == request.id, generation == request.generation else { return }
        appleTranslationRequest = nil
        retryResult(.appleTranslation)
    }

    func completeAppleTranslation(_ request: AppleTranslationRequest, text: String) {
        guard appleTranslationRequest?.id == request.id, generation == request.generation else { return }
        appleTranslationRequest = nil
        finishResult(
            .appleTranslation,
            text: text,
            generation: request.generation
        )
    }

    func failAppleTranslation(_ request: AppleTranslationRequest, error: Error) {
        guard appleTranslationRequest?.id == request.id, generation == request.generation else { return }
        appleTranslationRequest = nil
        if !(error is CancellationError) {
            failResult(.appleTranslation, error: error, generation: request.generation)
        }
    }

    private func finishDictionary(
        _ outcome: Result<DictionaryEntry?, Error>,
        generation id: UUID
    ) {
        guard generation == id, let index = resultIndex(.ecdict) else { return }
        serviceTasks[.ecdict] = nil
        switch outcome {
        case .success(let entry?):
            serviceResults[index].dictionaryEntry = entry
            serviceResults[index].text = entry.formattedText
            serviceResults[index].phase = .success
            saveHistoryResult(serviceResults[index])
        case .success(nil):
            // 未收录不是错误，重试也不会有结果：灰色说明，不带重试。
            serviceResults[index].phase = .skipped
            serviceResults[index].issue = Self.dictionaryMissIssue
        case .failure(let error):
            serviceResults[index].phase = .failure
            serviceResults[index].issue = .key("couldNotReadTheOfflineDictionaryDelete")
            // 按 AGENTS.md 只记录错误类型，不记录错误说明或查询词。
            let reason = (error as? ECDictionaryError)?.diagnosticCategory
                ?? String(describing: type(of: error))
            Task { await logger.record(.warning, "dictionary_query_failed", metadata: ["reason": reason]) }
        }
        refreshOverallState(generation: id)
    }

    private func finishResult(
        _ provider: TranslationProviderID,
        text: String,
        generation id: UUID,
        dictionaryEntry: DictionaryEntry? = nil
    ) {
        guard generation == id, let index = resultIndex(provider) else { return }
        serviceTasks[provider] = nil
        var result = serviceResults[index]
        result.text = text
        result.dictionaryEntry = dictionaryEntry
        result.phase = .success
        result.issue = nil
        serviceResults[index] = result
        saveHistoryResult(result)
        refreshOverallState(generation: id)
    }

    private func saveHistoryResult(_ result: TranslationServiceResult) {
        guard let history, let round = historyRound else { return }
        let text: String
        if result.isTranslation {
            text = result.text
        } else {
            guard let dictionary = result.dictionaryEntry else { return }
            let hasDefinition = dictionary.blocks.contains {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let english = dictionary.englishDefinitions.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let hasPhraseMeaning = dictionary.phrases.contains { phrase in
                phrase.meanings.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
            guard hasDefinition || !english.isEmpty || hasPhraseMeaning else { return }
            text = ([result.text] + english).joined(separator: "\n")
        }
        let saved = TranslationRecord.Result(providerID: result.id, providerName: result.title, translatedText: text)
        if let record = round.record {
            history.updateRecord(record, result: saved, providerOrder: serviceResults.map(\.id))
        } else {
            historyRound?.record = history.beginRecord(
                sourceText: round.sourceText, sourceLanguage: round.sourceLanguage,
                targetLanguage: round.targetLanguage, result: saved
            )
        }
    }

    private func startOnlineTranslation(
        _ provider: TranslationProviderID,
        service: OnlineTranslationServing,
        request: OnlineTranslationRequest,
        generation id: UUID
    ) {
        let start = Date()
        let task = Task { [weak self, logger] in
            guard let self else { return }
            do {
                let output = try await service.translate(request)
                guard self.generation == id, !Task.isCancelled else { return }
                self.finishResult(
                    provider,
                    text: output.text,
                    generation: id,
                    dictionaryEntry: output.dictionaryEntry
                )
                await logger.record(.info, "translation_succeeded", metadata: [
                    "elapsed_ms": String(Int(Date().timeIntervalSince(start) * 1_000)),
                    "host": provider == .youdao ? (YoudaoTranslationService.translationEndpoint.host(percentEncoded: false) ?? "") : (GoogleTranslationService.endpoint.host(percentEncoded: false) ?? ""),
                    "characters": String(request.text.count)
                ])
            } catch {
                // 已取消的请求（例如服务被停用后又重新启用）迟到的错误不能覆盖新请求的状态。
                guard self.generation == id, !Task.isCancelled else { return }
                if !(error is CancellationError) {
                    self.failResult(provider, error: error, generation: id)
                    await logger.record(.error, "translation_failed", metadata: [
                        "host": provider == .youdao ? (YoudaoTranslationService.translationEndpoint.host(percentEncoded: false) ?? "") : (GoogleTranslationService.endpoint.host(percentEncoded: false) ?? ""),
                        "reason": String(describing: type(of: error)),
                        "characters": String(request.text.count)
                    ])
                }
            }
        }
        serviceTasks[provider] = task
    }

    private func startCompatibleTranslation(
        _ provider: TranslationProviderID,
        request: TranslationRequest,
        generation id: UUID
    ) {
        let start = Date()
        let task = Task { [weak self, service, logger] in
            guard let self else { return }
            do {
                let result = try await service.translateStream(request) { partial in
                    await self.applyStreamingUpdate(partial, provider: provider, generation: id)
                }
                guard self.generation == id, !Task.isCancelled else { return }
                self.finishResult(
                    provider,
                    text: result,
                    generation: id
                )
                await logger.record(.info, "translation_succeeded", metadata: [
                    "elapsed_ms": String(Int(Date().timeIntervalSince(start) * 1_000)),
                    "host": request.configuration.hostLabel,
                    "characters": String(request.text.count)
                ])
            } catch {
                // 已取消的请求（例如服务被停用后又重新启用）迟到的错误不能覆盖新请求的状态。
                guard self.generation == id, !Task.isCancelled else { return }
                if !(error is CancellationError) {
                    self.failResult(provider, error: error, generation: id)
                    await logger.record(.error, "translation_failed", metadata: [
                        "host": request.configuration.hostLabel,
                        "reason": String(describing: type(of: error)),
                        "characters": String(request.text.count)
                    ])
                }
            }
        }
        serviceTasks[provider] = task
    }

    private func failResult(_ provider: TranslationProviderID, error: Error, generation id: UUID) {
        guard generation == id, let index = resultIndex(provider) else { return }
        serviceTasks[provider] = nil
        if error as? TranslationError == .incomplete { serviceResults[index].text = "" }
        if case .unsupportedLanguage(let message)? = error as? TranslationError {
            serviceResults[index].text = ""
            serviceResults[index].phase = .skipped
            serviceResults[index].issue = message
        } else {
            serviceResults[index].phase = .failure
            serviceResults[index].issue = .forError(error)
        }
        refreshOverallState(generation: id)
    }

    internal func refreshOverallState(generation id: UUID) {
        guard generation == id else { return }
        let running = serviceResults.filter { $0.phase.isRunning }.count
        isLoading = running > 0
        if running > 0 {
            status = "正在获取 \(running) 项结果…"
            return
        }

        let successful = serviceResults.filter { $0.phase == .success }
        if successful.isEmpty {
            // 只取真正失败的结果；“已跳过”（不支持该语言、未收录等）不是错误。
            let failures = serviceResults.filter { $0.phase == .failure }
            let primaryError = primaryResultID
                .flatMap { provider in failures.first(where: { $0.id == provider })?.issue }
            issue = primaryError ?? failures.compactMap(\.issue).first
            recoveryAction = serviceResults.contains(where: { !$0.id.isBuiltIn }) ? .serviceSettings : nil
            status = "翻译未完成"
        } else {
            issue = nil
            recoveryAction = nil
            status = successful.count == 1
                ? "翻译完成 · \(LanguageCatalog.name(resolvedTarget ?? target))"
                : "已完成 \(successful.count) 个服务 · \(LanguageCatalog.name(resolvedTarget ?? target))"
        }
        serviceTasks.removeAll()
        appleTranslationRequest = nil
        generation = nil
    }

    internal func resultIndex(_ provider: TranslationProviderID) -> Int? {
        serviceResults.firstIndex { $0.id == provider }
    }

    private static func localeIdentifier(for language: String) -> String? {
        LanguageCatalog.language(language)?.appleLocale
    }

    private func applyStreamingUpdate(
        _ partial: String,
        provider: TranslationProviderID,
        generation id: UUID
    ) {
        guard generation == id, !Task.isCancelled, let index = resultIndex(provider) else { return }
        serviceResults[index].text = partial
        serviceResults[index].phase = .streaming
    }

}
