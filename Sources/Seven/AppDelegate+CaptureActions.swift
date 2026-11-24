import AppKit

extension AppDelegate {
    @objc func selectionTranslate() { handleSelectionHotKey() }
    @objc func translateAndReplace() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        cancelSelectionWork(); cancelScreenshotWork()
        inputReplacement.start(pid: pid)
    }
    @objc func screenshotTranslate() { startScreenshotTranslation() }

    @objc func captureScreenshot() { startImageCapture(mode: .region) }
    @objc func captureFullScreen() { startImageCapture(mode: .fullScreen) }
    @objc func capturePreviousArea() { startImageCapture(mode: .previousArea) }

    @objc func captureLongScreenshot() {
        guard canOpenImageEntry else { return }
        inputReplacement.cancel(); cancelSelectionWork(); cancelScreenshotWork()
        ocrWindowController?.close()
        let token = screenshotGate.begin()
        frozenScreenshotCapture.start(purpose: .scroll) { [weak self] result in
            guard let self, self.screenshotGate.finish(token) else { return }
            switch result {
            case .success:
                if let rect = self.frozenScreenshotCapture.lastCaptureRect { self.startScrollCapture(in: rect) }
            case .failure(.cancelled): break
            case .failure(let error):
                ScreenshotCaptureErrorAlert.show(error)
            }
        }
    }

    private enum ImageCaptureMode { case region, fullScreen, previousArea }
    private func startImageCapture(mode: ImageCaptureMode) {
        // 已有采集或编辑覆盖层时跳过截图，避免把覆盖层拍进底图。
        guard !frozenScreenshotCapture.isCapturing, scrollCapture == nil,
              !screenshotEditors.contains(where: { $0.window?.isVisible == true }) else { return }
        inputReplacement.cancel()
        cancelSelectionWork()
        cancelScreenshotWork()
        screenshotEditors.removeAll { $0.window?.isVisible != true }
        let completion: FrozenScreenshotCaptureCoordinator.Completion = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let image):
                guard let context = self.frozenScreenshotCapture.lastSelectionContext else {
                    ScreenshotCaptureErrorAlert.show(.captureFailed)
                    return
                }
                let editor = ScreenshotEditorWindowController(image: image, context: .selection(context))
                self.configureScreenshotEditor(editor, captureRect: self.frozenScreenshotCapture.lastCaptureRect)
                self.presentScreenshotEditor(editor)
            case .failure(.cancelled): break
            case .failure(let error):
                ScreenshotCaptureErrorAlert.show(error)
            }
        }
        switch mode {
        case .region: frozenScreenshotCapture.start(completion: completion)
        case .fullScreen: frozenScreenshotCapture.captureFullScreen(completion: completion)
        case .previousArea: frozenScreenshotCapture.capturePreviousArea(completion: completion)

        }
    }

    internal func handleSelectionHotKey() {
        inputReplacement.cancel()
        let anchor = NSEvent.mouseLocation
        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        cancelScreenshotWork()
        cancelSelectionWork()
        model.cancel()
        let generation = selectionGate.begin()
        selectionTask = Task { [weak self, selectionReader] in
            guard let self else { return }
            do {
                let selection = try await selectionReader.readSelection(applicationPID: targetPID)
                guard selectionGate.accepts(generation), !Task.isCancelled else { return }
                await logger.record(.info, "selection_read_succeeded", metadata: [
                    "characters": String(selection.text.count),
                    "has_bounds": String(selection.appKitBounds != nil)
                ])
                model.prepareSelectedText(selection.text)
                presentPanel(near: anchor, avoiding: selection.appKitBounds)
                model.translate()
                selectionGate.finish(generation)
                selectionTask = nil
            } catch is CancellationError {
                return
            } catch let error as SelectionReadError {
                guard selectionGate.accepts(generation), !Task.isCancelled else { return }
                await logger.record(.warning, "selection_read_failed", metadata: ["reason": String(describing: type(of: error))])
                model.presentSelectionError(error)
                if error == .accessibilityPermission {
                    PermissionGuide.shared.authorize(.accessibility)
                } else {
                    presentPanel(near: anchor)
                }
                selectionGate.finish(generation)
                selectionTask = nil
            } catch {
                guard selectionGate.accepts(generation), !Task.isCancelled else { return }
                await logger.record(.warning, "selection_read_failed", metadata: ["reason": "unknown"])
                model.presentSelectionError(.noSelection)
                presentPanel(near: anchor)
                selectionGate.finish(generation)
                selectionTask = nil
            }
        }
    }

    internal func startScreenshotTranslation() {
        guard !frozenScreenshotCapture.isCapturing, scrollCapture == nil,
              !screenshotEditors.contains(where: { $0.window?.isVisible == true }) else { return }
        inputReplacement.cancel()
        cancelSelectionWork()
        cancelScreenshotWork()
        model.cancel()
        let generation = screenshotGate.begin()
        let anchor = NSEvent.mouseLocation
        Task { await logger.record(.info, "screenshot_requested", metadata: [
            "shortcut": screenshotHotKeyManager.shortcut.displayName
        ]) }
        frozenScreenshotCapture.start(purpose: .translation) { [weak self] result in
            guard let self, screenshotGate.accepts(generation) else { return }
            switch result {
            case .success(let image):
                screenshotTask = Task {
                    do {
                        guard let cg = ScreenshotSaving.bitmap(image)?.cgImage else { throw ScreenshotTranslationError.captureFailed }
                        let result = try await self.textRecognizer.recognizeText(in: cg)
                        guard self.screenshotGate.accepts(generation), !Task.isCancelled else { return }
                        await self.logger.record(.info, "screenshot_ocr_succeeded", metadata: [
                            "characters": String(result.text.count),
                            "confidence": String(format: "%.3f", result.averageConfidence)
                        ])
                        let needsReview = OCRQualityPolicy.needsReview(result)
                        self.model.prepareScreenshotText(
                            result.text,
                            needsReview: needsReview
                        )
                        self.presentPanel(near: anchor)
                        if needsReview {
                            await self.logger.record(.warning, "screenshot_ocr_needs_review", metadata: [
                                "confidence": String(format: "%.3f", result.averageConfidence)
                            ])
                        } else {
                            self.model.translate()
                        }
                    } catch let error as ScreenshotTranslationError {
                        guard self.screenshotGate.accepts(generation), !Task.isCancelled else { return }
                        await self.logger.record(.warning, "screenshot_ocr_failed", metadata: ["reason": String(describing: type(of: error))])
                        self.model.presentScreenshotError(error)
                        self.presentPanel(near: anchor)
                    } catch {
                        guard self.screenshotGate.accepts(generation), !Task.isCancelled else { return }
                        await self.logger.record(.warning, "screenshot_ocr_failed", metadata: ["reason": String(describing: type(of: error))])
                        self.model.presentScreenshotError(.noText)
                        self.presentPanel(near: anchor)
                    }
                    guard self.screenshotGate.finish(generation) else { return }
                    self.screenshotTask = nil
                }
            case .failure(.cancelled):
                screenshotGate.finish(generation)
                Task { await self.logger.record(.info, "screenshot_cancelled", metadata: [:]) }
            case .failure(let error):
                screenshotGate.finish(generation)
                Task { await self.logger.record(.warning, "screenshot_capture_failed", metadata: [
                    "reason": String(describing: type(of: error))
                ]) }
                model.presentScreenshotError(error)
                presentPanel(near: anchor)
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
    }

    internal func cancelScreenshotWork() {
        ocrCoordinator.cancel()
        screenshotGate.invalidate()
        screenshotTask?.cancel()
        screenshotTask = nil
        frozenScreenshotCapture.cancel()
        scrollCapture?.close(); scrollCapture = nil
    }

    internal func cancelSelectionWork() {
        selectionGate.invalidate()
        selectionTask?.cancel()
        selectionTask = nil
    }

}
