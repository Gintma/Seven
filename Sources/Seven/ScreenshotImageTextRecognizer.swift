import AppKit
import Vision
import CoreImage

/// Screenshot OCR: prioritizes local QR detection; uses Vision accurate mode for text while preserving line boxes for smart layout.
struct ScreenshotImageTextRecognizer: TextRecognizing {
    var language: String = LanguageCatalog.automatic
    func recognizeText(in image: CGImage) async throws -> RecognizedOCRText {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.minimumTextHeight = 0.001
        request.automaticallyDetectsLanguage = language == LanguageCatalog.automatic
        if language != LanguageCatalog.automatic { request.recognitionLanguages = [language] }
        request.usesLanguageCorrection = false
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let input = CIImage(cgImage: image)
            let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            let codes = detector?.features(in: input).compactMap { ($0 as? CIQRCodeFeature)?.messageString } ?? []
            try Task.checkCancellation()
            if !codes.isEmpty { return RecognizedOCRText(text: codes.joined(separator: "\n"), averageConfidence: 1) }
            do {
                try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            } catch {
                try Task.checkCancellation()
                throw error
            }
            try Task.checkCancellation()
            let lines = (request.results ?? []).compactMap { observation -> OCRTextLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return OCRTextLine(text: candidate.string, boundingBox: observation.boundingBox, confidence: candidate.confidence)
            }
            let text = lines.map(\.text).joined(separator: "\n")
            guard !text.isEmpty else { throw ScreenshotTranslationError.noText }
            return RecognizedOCRText(text: text, averageConfidence: lines.reduce(0) { $0 + $1.confidence } / Float(lines.count), lines: lines)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
            request.cancel()
        }
    }
}

/// Snapshots OCR preferences when starting a task so silent capture and the result window share the same recognition languages.
struct OCRPreferredTextRecognizer: TextRecognizing {
    func recognizeText(in image: CGImage) async throws -> RecognizedOCRText {
        let language = UserDefaults.standard.string(forKey: OCRRecognitionLanguages.preferenceKey) ?? LanguageCatalog.automatic
        let supported = OCRRecognitionLanguages.supported()
        return try await ScreenshotImageTextRecognizer(language: supported.contains(language) ? language : LanguageCatalog.automatic).recognizeText(in: image)
    }
}
