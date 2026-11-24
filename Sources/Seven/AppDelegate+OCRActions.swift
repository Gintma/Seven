import AppKit

extension AppDelegate {
    @objc func captureOCR() { startOCR(.standard) }
    func startOCR(_ mode:OCRMode) {
        guard !frozenScreenshotCapture.isCapturing,scrollCapture == nil,
              !screenshotEditors.contains(where:{$0.window?.isVisible==true}) else{return}
        inputReplacement.cancel();cancelSelectionWork();cancelScreenshotWork();model.cancel()
        ocrWindowController?.close() // 保留旧结果，避免把自身结果窗口冻结进这次框选。
        let token=screenshotGate.begin()
        frozenScreenshotCapture.start(purpose: .ocr) { [weak self] result in
            guard let self,self.screenshotGate.accepts(token) else{return}
            switch result {
            case .success(let image):
                self.ocrCoordinator.start(image:image,mode:mode,completed:{ [weak self] result in
                    guard let self,self.screenshotGate.finish(token) else{return}
                    if let result {self.showRecognizedOCR(result, image: image)}
                    if ScreenshotCapturePreferences(defaults:.standard).completionSound {ScreenshotCompletionSound.play()}
                },failed:{ [weak self] error in
                    guard let self,self.screenshotGate.finish(token) else{return}
                    self.showOCRError(error.localizedDescription)
                })
            case .failure(.cancelled):self.screenshotGate.finish(token)
            case .failure(let error):
                self.screenshotGate.finish(token)
                if error == .permissionDenied {
                    ScreenshotCaptureErrorAlert.show(error)
                } else {
                    self.showOCRError(error.localizedDescription)
                }
            }
        }
    }
    private func showOCRError(_ message:String) {
        let alert=NSAlert();alert.messageText=L10n.text("ocrFailed");alert.informativeText=message;alert.runModal()
    }
}
