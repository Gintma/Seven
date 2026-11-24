import AppKit

/// 两个独立框选入口共用本机识别；不读取或保存截图内容，不自动翻译。
enum OCRMode:String,CaseIterable,Identifiable {
    case standard,silent
    var id:Self {self}
    var titleMessage: LocalizedMessage { self == .standard ? "OCR" : .key("silentOCR") }
    var title: String { titleMessage.text }
    var explanation:String {self == .standard ? L10n.text("selectAnAreaToRecognizeTextOn"):L10n.text("selectAnAreaToRecognizeAndCopy")}
}

enum OCRFailure:LocalizedError,Equatable {
    case imageUnavailable,noText,recognitionFailed,clipboardWriteFailed
    var errorDescription:String? {
        switch self {
        case .imageUnavailable:return L10n.text("couldNotReadTheSelectedImageSelect")
        case .noText:return L10n.text("noTextWasRecognizedInTheSelection")
        case .recognitionFailed:return L10n.text("textRecognitionFailedSelectTheAreaAgain")
        case .clipboardWriteFailed:return L10n.text("couldNotCopyTheRecognizedTextTry")
        }
    }
}

@MainActor final class OCRCoordinator {
    private let recognizer:TextRecognizing
    private let copyText:(String)->Bool
    private var generation=UUID()
    private(set) var task:Task<Void,Never>?
    init(recognizer:TextRecognizing? = nil,copyText:((String)->Bool)? = nil) {
        self.recognizer=recognizer ?? OCRPreferredTextRecognizer()
        self.copyText=copyText ?? {text in NSPasteboard.general.clearContents();return NSPasteboard.general.setString(text,forType:.string)}
    }
    func start(image:NSImage,mode:OCRMode,completed:@escaping(RecognizedOCRText?)->Void,failed:@escaping(OCRFailure)->Void) {
        cancel()
        guard let cg=ScreenshotSaving.bitmap(image)?.cgImage else{failed(.imageUnavailable);return}
        let token=generation,recognizer=recognizer
        task=Task { [weak self] in
            do {
                let result=try await recognizer.recognizeText(in:cg)
                guard let self,self.generation==token,!Task.isCancelled else{return}
                self.task=nil
                guard !result.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{failed(.noText);return}
                if mode == .silent {
                    guard self.copyText(result.text) else{failed(.clipboardWriteFailed);return}
                    completed(nil)
                } else {completed(result)}
            } catch {
                guard let self,self.generation==token,!Task.isCancelled else{return}
                self.task=nil
                if error is CancellationError {return}
                failed((error as? ScreenshotTranslationError) == .noText ? .noText:.recognitionFailed)
            }
        }
    }
    func cancel() {generation=UUID();task?.cancel();task=nil}
}

@MainActor final class OCRShortcuts {
    let standard:HotKeyManager
    let silent:HotKeyManager
    let openWindow:HotKeyManager
    let clipboard:HotKeyManager
    let file:HotKeyManager
    init(defaults:UserDefaults? = .standard) {
        standard=HotKeyManager(defaults:defaults,storageKey:"ocr.captureHotKey.v1",identifierID:12,actionLabel:"OCR",allowsUnset:true)
        silent=HotKeyManager(defaults:defaults,storageKey:"ocr.silentCaptureHotKey.v1",identifierID:13,actionLabel:"静默 OCR",allowsUnset:true)
        openWindow=HotKeyManager(defaults:defaults,storageKey:"ocr.openWindowHotKey.v1",identifierID:14,actionLabel:"打开 OCR 窗口",allowsUnset:true)
        clipboard=HotKeyManager(defaults:defaults,storageKey:"ocr.clipboardHotKey.v1",identifierID:18,actionLabel:"剪贴板 OCR",allowsUnset:true)
        file=HotKeyManager(defaults:defaults,storageKey:"ocr.fileHotKey.v1",identifierID:19,actionLabel:"本地图片 OCR",allowsUnset:true)
    }
    func manager(_ mode:OCRMode)->HotKeyManager {mode == .standard ? standard:silent}
    var managers:[HotKeyManager] {[standard,silent,openWindow,clipboard,file]}
}
