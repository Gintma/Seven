import AppKit
import CoreGraphics
import Foundation
import Vision

enum ScreenshotTranslationError: LocalizableIssue, Equatable {
    case permissionDenied
    case cancelled
    case captureFailed
    case noText

    var issue: LocalizedMessage {
        switch self {
        case .permissionDenied: return .key("sevenNeedsScreenRecordingPermissionToCapture")
        case .cancelled: return .verbatim("已取消截图翻译。")
        case .captureFailed: return .key("couldNotCaptureTheSelectedAreaSelect")
        case .noText: return .key("noTextWasRecognizedInTheSelected")
        }
    }
}

struct OCRTextLine: Equatable, Sendable {
    let text: String
    let boundingBox: CGRect
    let confidence: Float

    init(text: String, boundingBox: CGRect, confidence: Float = 1) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

struct RecognizedOCRText: Equatable, Sendable {
    let text: String
    let averageConfidence: Float
    var lines: [OCRTextLine] = []
}

enum OCRQualityPolicy {
    static func needsReview(_ result: RecognizedOCRText) -> Bool {
        guard !result.text.isEmpty else { return true }
        let replacementCharacters = result.text.filter { $0 == "\u{FFFD}" }.count
        let replacementRatio = Double(replacementCharacters) / Double(result.text.count)
        return result.averageConfidence < 0.45 || replacementRatio > 0.02
    }
}

enum ScreenshotGeometry {
    static func displayRect(
        for localRect: CGRect,
        screenSize: CGSize,
        displaySpaceSize: CGSize
    ) -> CGRect {
        let scaleX = displaySpaceSize.width / screenSize.width
        let scaleY = displaySpaceSize.height / screenSize.height
        let rect = CGRect(
            x: localRect.minX * scaleX,
            y: (screenSize.height - localRect.maxY) * scaleY,
            width: localRect.width * scaleX,
            height: localRect.height * scaleY
        ).integral
        return rect.intersection(CGRect(origin: .zero, size: displaySpaceSize))
    }
}

enum OCRTextLayout {
    static func text(from lines: [OCRTextLine]) -> String {
        lines.map(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol TextRecognizing: Sendable {
    func recognizeText(in image: CGImage) async throws -> RecognizedOCRText
}

struct VisionTextRecognizer: TextRecognizing {
    func recognizeText(in image: CGImage) async throws -> RecognizedOCRText {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: image)
            try handler.perform([request])
            let lines = (request.results ?? []).compactMap { observation -> OCRTextLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return OCRTextLine(
                    text: candidate.string,
                    boundingBox: observation.boundingBox,
                    confidence: candidate.confidence
                )
            }
            let result = OCRTextLayout.text(from: lines)
            guard !result.isEmpty else { throw ScreenshotTranslationError.noText }
            let confidence = lines.reduce(0) { $0 + $1.confidence } / Float(lines.count)
            return RecognizedOCRText(text: result, averageConfidence: confidence)
        }.value
    }
}
