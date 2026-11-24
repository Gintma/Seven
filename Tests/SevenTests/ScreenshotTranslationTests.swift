import AppKit
import XCTest
@testable import Seven

final class ScreenshotTranslationTests: XCTestCase {
    @MainActor
    private func renderedImage(lines: [String], fontSize: CGFloat) throws -> CGImage {
        let pointSize = NSSize(width: 1_200, height: 260)
        let image = NSImage(size: pointSize)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: pointSize).fill()
        for (index, line) in lines.enumerated() {
            line.draw(
                at: NSPoint(x: 36, y: 190 - CGFloat(index) * (fontSize * 1.65)),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                    .foregroundColor: NSColor.black
                ]
            )
        }
        image.unlockFocus()
        var rect = NSRect(origin: .zero, size: pointSize)
        return try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
    }

    func testOCRLinesPreserveVisionResultOrder() {
        let lines = [
            OCRTextLine(text: "right", boundingBox: CGRect(x: 0.55, y: 0.7, width: 0.3, height: 0.1)),
            OCRTextLine(text: "bottom", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1)),
            OCRTextLine(text: "left", boundingBox: CGRect(x: 0.1, y: 0.72, width: 0.3, height: 0.1))
        ]

        XCTAssertEqual(OCRTextLayout.text(from: lines), "right\nbottom\nleft")
    }

    func testEmptyOCRLayoutProducesEmptyString() {
        XCTAssertEqual(OCRTextLayout.text(from: []), "")
    }

    func testDisplayRectFlipsYAxisWithoutAssumingRetinaScale() {
        let result = ScreenshotGeometry.displayRect(
            for: CGRect(x: 10, y: 20, width: 100, height: 50),
            screenSize: CGSize(width: 800, height: 600),
            displaySpaceSize: CGSize(width: 800, height: 600)
        )

        XCTAssertEqual(result, CGRect(x: 10, y: 530, width: 100, height: 50))
    }

    func testDisplayRectScalesRetinaCoordinatesOnEitherAxis() {
        let result = ScreenshotGeometry.displayRect(
            for: CGRect(x: 40, y: 80, width: 300, height: 120),
            screenSize: CGSize(width: 1_920, height: 1_080),
            displaySpaceSize: CGSize(width: 3_840, height: 2_160)
        )

        XCTAssertEqual(result, CGRect(x: 80, y: 1_760, width: 600, height: 240))
    }

    func testDisplayRectUsesDisplayLocalCoordinatesForSecondaryScreen() {
        let result = ScreenshotGeometry.displayRect(
            for: CGRect(x: 0, y: 0, width: 1_280, height: 800),
            screenSize: CGSize(width: 1_280, height: 800),
            displaySpaceSize: CGSize(width: 2_560, height: 1_600)
        )

        XCTAssertEqual(result, CGRect(x: 0, y: 0, width: 2_560, height: 1_600))
    }

    func testOCRQualityPolicyRequestsReviewForLowConfidenceOrCorruptText() {
        XCTAssertTrue(OCRQualityPolicy.needsReview(.init(
            text: "uncertain text",
            averageConfidence: 0.44
        )))
        XCTAssertTrue(OCRQualityPolicy.needsReview(.init(
            text: "损坏\u{FFFD}文本",
            averageConfidence: 0.95
        )))
        XCTAssertFalse(OCRQualityPolicy.needsReview(.init(
            text: "Clear text 清晰文字",
            averageConfidence: 0.8
        )))
    }

    func testDisplayRectClampsIntegralRectToDisplaySpace() {
        let result = ScreenshotGeometry.displayRect(
            for: CGRect(x: 799.4, y: 0.2, width: 1, height: 1),
            screenSize: CGSize(width: 800, height: 600),
            displaySpaceSize: CGSize(width: 800, height: 600)
        )

        XCTAssertEqual(result, CGRect(x: 799, y: 598, width: 1, height: 2))
    }

    @MainActor
    func testVisionRecognizerReadsChineseMultilineImage() async throws {
        let image = try renderedImage(
            lines: ["清晨的风穿过安静街道", "每一次出发都值得期待"],
            fontSize: 38
        )

        let result = try await VisionTextRecognizer().recognizeText(in: image)

        XCTAssertTrue(result.text.contains("清晨的风"))
        XCTAssertTrue(result.text.contains("安静街道"))
        XCTAssertTrue(result.text.contains("每一次出发"))
        XCTAssertTrue(result.text.contains("值得期待"))
    }

    @MainActor
    func testVisionRecognizerReadsEnglishMultilineImage() async throws {
        let image = try renderedImage(
            lines: ["A clear interface reduces friction.", "Reliable tools respect your focus."],
            fontSize: 34
        )

        let result = try await VisionTextRecognizer().recognizeText(in: image)

        XCTAssertTrue(result.text.contains("A clear interface reduces friction."))
        XCTAssertTrue(result.text.contains("Reliable tools respect your focus."))
    }

    @MainActor
    func testVisionRecognizerReadsMixedLanguageImage() async throws {
        let image = try renderedImage(
            lines: ["工具 Seven keeps context 清晰", "Build 16 validates OCR and translation."],
            fontSize: 30
        )

        let result = try await VisionTextRecognizer().recognizeText(in: image)

        XCTAssertTrue(result.text.contains("工具"))
        XCTAssertTrue(result.text.contains("Seven keeps context"))
        XCTAssertTrue(result.text.contains("清晰"))
        XCTAssertTrue(result.text.contains("validates OCR and translation"))
    }

    @MainActor
    func testVisionRecognizerReadsSmallMultilineImage() async throws {
        let image = try renderedImage(
            lines: [
                "Small text should remain readable after a Retina screenshot.",
                "小字号识别需要正确的像素坐标与清晰裁切。",
                "Numbers: 2026 / 10 / 15 - Symbols: API, OCR, macOS."
            ],
            fontSize: 17
        )

        let result = try await VisionTextRecognizer().recognizeText(in: image)

        XCTAssertTrue(result.text.contains("Small text should remain readable"))
        XCTAssertTrue(result.text.contains("小字号识别"))
        XCTAssertTrue(result.text.contains("像素坐标"))
        XCTAssertTrue(result.text.contains("2026 / 10 / 15"))
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains("API, OCR, macOS"))
    }
}
