import AppKit
import VisionKit
import XCTest
@testable import Seven

@MainActor private final class HeldImageAnalysis: OCRImageAnalyzing {
    private var continuations: [String: CheckedContinuation<ImageAnalysis?, Never>] = [:]
    private(set) var languages: [String] = []
    private(set) var inputSizes: [CGSize] = []
    func analyze(_ input: OCRImageAnalysisInput, language: String) async throws -> ImageAnalysis? {
        languages.append(language)
        if case .raster(let image) = input {
            inputSizes.append(CGSize(width: image.width, height: image.height))
        }
        return await withCheckedContinuation { continuations[language] = $0 }
    }
    func finish(_ language: String) { continuations.removeValue(forKey: language)?.resume(returning: nil) }
}

@MainActor private struct ReadyImageAnalysis: OCRImageAnalyzing {
    let analysis: ImageAnalysis
    func analyze(_ input: OCRImageAnalysisInput, language: String) async throws -> ImageAnalysis? { analysis }
}

@MainActor final class OCRImageSelectionTests: XCTestCase {
    func testLargePreviewReleasesOriginalWhileAnalysisIsStillPending() async throws {
        let analyzer = HeldImageAnalysis()
        let context = try XCTUnwrap(CGContext(data: nil, width: 7_680, height: 4_320,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let raster = try XCTUnwrap(context.makeImage())
        var original: NSImage? = NSImage(cgImage: raster, size: CGSize(width: 3_840, height: 2_160))
        weak let originalReference = original
        let preview = OCRImagePreview(image: try XCTUnwrap(original), analyzer: analyzer)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = preview
        defer { preview.cancelAnalysis(); analyzer.finish(LanguageCatalog.automatic); window.close() }

        for _ in 0..<200 where analyzer.languages.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let input = try XCTUnwrap(analyzer.inputSizes.first)
        XCTAssertLessThanOrEqual(input.width * input.height, 8 * 1_024 * 1_024)
        XCTAssertEqual(input.width / input.height, 7_680.0 / 4_320, accuracy: 0.001)
        XCTAssertTrue(preview.image === original)

        preview.replaceDisplayedImage(nil)
        original = nil
        for _ in 0..<100 where originalReference != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(originalReference, "分析尚未返回时也必须能释放原图")
    }

    func testHidingPreviewCancelsPendingAnalysisAndReopeningRestartsIt() async throws {
        let analyzer = HeldImageAnalysis()
        let preview = OCRImagePreview(image: NSImage(size: CGSize(width: 100, height: 100)), analyzer: analyzer)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = preview
        defer { preview.cancelAnalysis(); analyzer.finish(LanguageCatalog.automatic); window.close() }

        for _ in 0..<100 where analyzer.languages.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(preview.isAnalyzing)
        preview.setPresentationActive(false)
        XCTAssertFalse(preview.isAnalyzing)
        analyzer.finish(LanguageCatalog.automatic)
        preview.setPresentationActive(true)
        for _ in 0..<100 where analyzer.languages.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(analyzer.languages, [LanguageCatalog.automatic, LanguageCatalog.automatic])
        XCTAssertTrue(preview.isAnalyzing, "旧响应不能结束重开的分析")
    }

    func testNativeTextSelectionWorksOnLongRasterWithoutChangingOriginalGeometry() async throws {
        guard ImageAnalyzer.isSupported else { throw XCTSkip("当前设备不支持本机实况文本") }
        _ = NSApplication.shared
        let size = CGSize(width: 1_804, height: 9_003)
        let textOrigins = [CGPoint(x: 160, y: 8_480), CGPoint(x: 160, y: 300)]
        let phrases = ["Upper Zebra", "Lower Panda"]
        let raster = try XCTUnwrap(autoreleasepool { () -> CGImage? in
            guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            defer { NSGraphicsContext.restoreGraphicsState() }
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 100),
                                                               .foregroundColor: NSColor.black]
            for (phrase, origin) in zip(phrases, textOrigins) {
                (phrase as NSString).draw(at: origin, withAttributes: attributes)
            }
            return context.makeImage()
        })
        let image = NSImage(cgImage: raster, size: size)
        let preview = OCRImagePreview(image: image)
        preview.recognitionLanguage = "en-US"
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 500, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = preview
        defer { preview.cancelAnalysis(); window.close() }
        window.orderBack(nil)
        for _ in 0..<500 where preview.isAnalyzing { try await Task.sleep(for: .milliseconds(10)) }
        let analysis = try XCTUnwrap(preview.textOverlay.analysis)
        for phrase in phrases {
            XCTAssertTrue(analysis.transcript.contains(phrase))
        }
        XCTAssertTrue(preview.image === image)
        XCTAssertEqual(preview.displayedImageRect.width / preview.displayedImageRect.height, size.width / size.height,
                       accuracy: 0.0001)
        for origin in textOrigins {
            let rect = preview.displayedImageRect
            let scale = rect.width / size.width
            var candidates: [CGPoint] = []
            for dy in stride(from: 15, through: 115, by: 10) {
                for dx in stride(from: 12, through: 535, by: 12) {
                    let x = rect.minX + (origin.x + CGFloat(dx)) * scale
                    let y = rect.minY + (origin.y + CGFloat(dy)) * scale
                    candidates.append(CGPoint(x: x, y: y))
                }
            }
            let point = try XCTUnwrap(candidates.first { preview.textOverlay.hasText(at: preview.analysisPoint(from: $0)) },
                                     "原图顶部和底部的两行都应可命中")
            let hit = preview.hitTest(preview.convert(point, to: preview.superview))
            XCTAssertNotNil(hit)
            XCTAssertFalse(hit === preview, "原图文字位置应把拖选交给 VisionKit")
        }
    }

    func testLanguageChangeAndDisposalRejectLateImageAnalyses() async throws {
        let analyzer = HeldImageAnalysis()
        let preview = OCRImagePreview(image: NSImage(size: NSSize(width: 100, height: 100)), analyzer: analyzer)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = preview
        defer { preview.cancelAnalysis(); window.close() }
        for _ in 0..<100 where analyzer.languages.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(analyzer.languages, [LanguageCatalog.automatic])
        preview.recognitionLanguage = "ja-JP"
        for _ in 0..<100 where analyzer.languages.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(analyzer.languages, [LanguageCatalog.automatic, "ja-JP"])
        analyzer.finish(LanguageCatalog.automatic)
        await Task.yield()
        XCTAssertTrue(preview.isAnalyzing, "旧响应不能结束新语言的分析")
        preview.cancelAnalysis(); analyzer.finish("ja-JP")
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(preview.isAnalyzing)
        XCTAssertNil(preview.textOverlay.analysis)
    }

    func testNativeTextSelectionAndHitMappingFollowZoomAndPan() async throws {
        guard ImageAnalyzer.isSupported else { throw XCTSkip("当前设备不支持本机实况文本") }
        _ = NSApplication.shared
        let image = NSImage(size: NSSize(width: 500, height: 240), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            ("Alpha Beta Gamma" as NSString).draw(at: CGPoint(x: 40, y: 160), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
            return true
        }
        let analyzed = try await SystemOCRImageAnalyzer().analyze(.original(image), language: "en-US")
        let analysis = try XCTUnwrap(analyzed)
        XCTAssertTrue(analysis.transcript.contains("Alpha"))
        var copied = ""
        let preview = OCRImagePreview(image: image, analyzer: ReadyImageAnalysis(analysis: analysis), clipboardWriter: { copied = $0; return true })
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 500, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = preview
        defer { preview.cancelAnalysis(); window.close() }
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<100 where preview.textOverlay.analysis == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(preview.textOverlay.preferredInteractionTypes, .textSelection)
        XCTAssertTrue(preview.textOverlay.isSupplementaryInterfaceHidden)
        let overlay = preview.textOverlay
        let range = try XCTUnwrap(overlay.text.range(of: "Alpha Beta"))
        overlay.selectedRanges = [range]
        XCTAssertEqual(overlay.selectedText, "Alpha Beta")
        let copyEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        XCTAssertTrue(preview.performKeyEquivalent(with: copyEvent))
        XCTAssertEqual(copied, "Alpha Beta")
        // 文字绘在图片上部；VisionKit查询点须按图像的左上原点转换。
        let candidates = stride(from: 165.0, through: 190.0, by: 2).flatMap { y in
            stride(from: 45.0, through: 220.0, by: 5).map { CGPoint(x: $0, y: y) }
        }
        let textPoint = try XCTUnwrap(candidates.first { overlay.hasText(at: preview.analysisPoint(from: $0)) })
        let originalRect = preview.displayedImageRect
        let u = (textPoint.x - originalRect.minX) / originalRect.width
        let v = (textPoint.y - originalRect.minY) / originalRect.height
        let normalizedHit = preview.analysisPoint(from: textPoint)
        preview.zoom(by: 1.4, around: CGPoint(x: 180, y: 110)); preview.pan(by: CGPoint(x: 12, y: -8))
        let transformed = CGPoint(x: preview.displayedImageRect.minX + u * preview.displayedImageRect.width,
                                  y: preview.displayedImageRect.minY + v * preview.displayedImageRect.height)
        let hit = preview.analysisPoint(from: transformed)
        XCTAssertEqual(hit.x / overlay.bounds.width, normalizedHit.x / originalRect.width, accuracy: 0.001)
        XCTAssertEqual(hit.y / overlay.bounds.height, normalizedHit.y / originalRect.height, accuracy: 0.001)
        for _ in 0..<100 where !overlay.hasText(at: hit) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(overlay.hasText(at: hit))
        XCTAssertEqual(overlay.selectedText, "Alpha Beta", "查看变换不改变原图选中文字")
        let blank = CGPoint(x: preview.bounds.minX + 2, y: preview.bounds.minY + 2)
        XCTAssertTrue(preview.hitTest(preview.superview?.convert(blank, from: preview) ?? blank) === preview)
        preview.reset()
        XCTAssertEqual(preview.displayedImageRect, originalRect)
        preview.clearSelectionIfOutside(CGPoint(x: -500, y: -500))
        XCTAssertFalse(overlay.hasActiveTextSelection)
        XCTAssertFalse(preview.overlayView(overlay, shouldHandleKeyDownEvent: copyEvent))
    }
}
