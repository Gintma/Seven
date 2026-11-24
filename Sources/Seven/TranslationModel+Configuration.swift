import AppKit

extension TranslationModel {
    // MARK: 服务配置与设置持久化
    func readCredential(for account: String) throws -> String { try credentials.read(account: account) }

    func resolvedCredential(for config: ServiceConfiguration, override: String? = nil) throws -> String {
        if let override {
            guard !override.contains("\n"), !override.contains("\r") else {
                throw TranslationError.configuration("API Key 中不能包含换行。")
            }
            let normalized = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty { return normalized }
        }
        let stored = try readCredential(for: config.credentialAccount)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored
    }

    func saveLanguagePair(primary: String, secondary: String) throws {
        guard Self.languages.contains(primary), Self.languages.contains(secondary) else {
            throw TranslationError.configuration("请选择支持的第一语言和第二语言。")
        }
        guard primary != secondary else {
            throw TranslationError.configuration("第一语言和第二语言不能相同。")
        }
        settings.primaryLanguage = primary
        settings.secondaryLanguage = secondary
        primaryLanguage = primary
        secondaryLanguage = secondary
        preferredDetectionLanguagesDidChange()
        resolvedTarget = nil
        Task { await logger.record(.info, "language_pair_saved", metadata: [
            "primary": primary,
            "secondary": secondary
        ]) }
    }

    func setPrimaryLanguage(_ code: String) {
        guard Self.languages.contains(code) else { return }
        let other = code == secondaryLanguage ? primaryLanguage : secondaryLanguage
        try? saveLanguagePair(primary: code, secondary: other)
    }

    func setSecondaryLanguage(_ code: String) {
        guard Self.languages.contains(code) else { return }
        let other = code == primaryLanguage ? secondaryLanguage : primaryLanguage
        try? saveLanguagePair(primary: other, secondary: code)
    }

    /// 添加时追加末尾，删除时保留其余顺序，至少保留一种。
    func setCommonLanguage(_ code: String, isCommon: Bool) {
        guard LanguageCatalog.language(code) != nil else { return }
        var updated = commonLanguages
        if isCommon {
            guard !updated.contains(code) else { return }
            updated.append(code)
        } else {
            guard updated.count > 1 else { return }
            updated.removeAll { $0 == code }
        }
        guard updated != commonLanguages else { return }
        commonLanguages = updated
        settings.commonLanguages = updated
    }

    func moveCommonLanguage(from offsets: IndexSet, to destination: Int) {
        guard !offsets.isEmpty, offsets.allSatisfy({ commonLanguages.indices.contains($0) }),
              (0...commonLanguages.count).contains(destination) else { return }
        var updated = commonLanguages
        updated.move(fromOffsets: offsets, toOffset: destination)
        guard updated != commonLanguages else { return }
        commonLanguages = updated
        settings.commonLanguages = updated
    }

    func setInputMaximumHeight(_ value: Int) {
        let normalized = TranslationWindowLayoutPreferences.normalizedInputMaximumHeight(value)
        guard normalized != inputMaximumHeight else { return }
        settings.inputMaximumHeight = normalized
        inputMaximumHeight = normalized
    }

    func setMaximumWindowHeightRatio(_ value: Double) {
        let normalized = TranslationWindowLayoutPreferences.normalizedMaximumWindowHeightRatio(value)
        guard normalized != maximumWindowHeightRatio else { return }
        settings.maximumWindowHeightRatio = normalized
        maximumWindowHeightRatio = normalized
    }

    func updatePanelScreenHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0, abs(panelScreenHeight - height) > 0.5 else { return }
        panelScreenHeight = height
    }

    func testConfiguration(_ config: ServiceConfiguration, key: String?, persistVerifiedStyle: Bool = true) {
        configurationTestTask?.cancel()
        let apiKey: String
        do {
            _ = try config.validatedURL()
            if let key {
                guard !key.contains("\n"), !key.contains("\r") else {
                    throw TranslationError.configuration(.key("theAPIKeyCannotContainLineBreaks"))
                }
                apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                apiKey = try resolvedCredential(for: config)
            }
        } catch {
            configurationTestSucceeded = false
            configurationTestIssue = .forError(error)
            return
        }

        isTestingConfiguration = true
        configurationTestIssue = nil
        configurationTestSucceeded = false
        let firstLanguage = primaryLanguage
        configurationTestTask = Task { [weak self, configurationTester, logger] in
            do {
                let result = try await configurationTester.test(configuration: config, apiKey: apiKey, firstLanguage: firstLanguage)
                guard let self, !Task.isCancelled else { return }
                if persistVerifiedStyle, let style = result.apiStyle { self.rememberVerifiedAPIStyle(style, configuration: config) }
                self.isTestingConfiguration = false
                self.configurationTestSucceeded = true
                self.configurationTestIssue = .verbatim(String(format: "连接成功 · %.1f 秒", result.elapsed))
                self.configurationTestTask = nil
                await logger.record(.info, "service_test_succeeded", metadata: [
                    "elapsed_ms": String(Int(result.elapsed * 1_000)),
                    "host": config.hostLabel
                ])
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isTestingConfiguration = false
                self.configurationTestSucceeded = false
                self.configurationTestIssue = .forError(error)
                self.configurationTestTask = nil
                await logger.record(.error, "service_test_failed", metadata: [
                    "host": config.hostLabel,
                    "reason": String(describing: type(of: error))
                ])
            }
        }
    }

    func clearConfigurationTestResult() {
        configurationTestTask?.cancel(); configurationTestTask = nil
        isTestingConfiguration = false
        configurationTestIssue = nil
        configurationTestSucceeded = false
    }
}
