import AppKit
import CoreGraphics
import ScreenCaptureKit

struct FrozenWindowCandidate: Equatable, Sendable {
    let id: CGWindowID
    let frame: CGRect
    let ownerPID: pid_t?
    init(id: CGWindowID, frame: CGRect, ownerPID: pid_t? = nil) {
        self.id = id; self.frame = frame; self.ownerPID = ownerPID
    }

    /// Preserves WindowServer z-order and matches only app windows; Dock has a full-screen transparent window that must be excluded.
    static func candidates(from info: [[String: Any]], primaryScreenTop: CGFloat, includingWindowIDs: Set<CGWindowID> = []) -> [Self] {
        info.compactMap { item in
            guard let layer = item[kCGWindowLayer as String] as? Int,
                  (item[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let number = item[kCGWindowNumber as String] as? NSNumber,
                  (0..<Int(CGWindowLevelForKey(.dockWindow))).contains(layer) || includingWindowIDs.contains(number.uint32Value),
                  let bounds = item[kCGWindowBounds as String] as? [String: NSNumber],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"] else { return nil }
            let quartz = CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
            guard quartz.width > 0, quartz.height > 0 else { return nil }
            return Self(id: number.uint32Value,
                        frame: CGRect(x: quartz.minX, y: primaryScreenTop - quartz.maxY, width: quartz.width, height: quartz.height),
                        ownerPID: (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value)
        }
    }
}

@MainActor
protocol IndependentWindowCapturing {
    func capture(_ candidate: FrozenWindowCandidate) async throws -> NSImage
}

@MainActor
struct SystemIndependentWindowCapture: IndependentWindowCapturing {
    func capture(_ candidate: FrozenWindowCandidate) async throws -> NSImage {
        // Look up the capture target by window ID and round the point-to-pixel scale factor.
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == candidate.id }) else { throw ScreenshotTranslationError.captureFailed }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = Int(filter.pointPixelScale)
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = false
        if #available(macOS 14.2, *) { configuration.includeChildWindows = false }
        configuration.showsCursor = false
        configuration.width = Int(candidate.frame.width * CGFloat(scale))
        configuration.height = Int(candidate.frame.height * CGFloat(scale))
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        return NSImage(cgImage: image, size: candidate.frame.size)
    }
}

/// Multi-selection on the same display preserves original WindowServer z-order; click order does not alter window stacking.
struct FrozenMultiWindowSelection {
    private(set) var screenFrame: CGRect?
    private(set) var ids: Set<CGWindowID> = []
    mutating func toggle(_ candidate: FrozenWindowCandidate, on screen: CGRect) {
        guard candidate.frame.intersects(screen), screenFrame == nil || screenFrame == screen else { return }
        screenFrame = screen
        if ids.contains(candidate.id) { ids.remove(candidate.id) } else { ids.insert(candidate.id) }
        if ids.isEmpty { screenFrame = nil }
    }
    func ordered(in candidates: [FrozenWindowCandidate]) -> [FrozenWindowCandidate] { candidates.filter { ids.contains($0.id) } }
}

/// Composites only the selected windows' standalone images; unselected windows and desktop stay out of union gaps with a transparent background.
/// Preserves the selected windows' on-screen stacking order during compositing.
enum FrozenMultiWindowComposition {
    static func selectionContext(candidates: [FrozenWindowCandidate], images: [NSImage], screenFrame: CGRect, backgroundImage: CGImage? = nil) -> FrozenSelectionContext? {
        guard let image = render(candidates: candidates, images: images, bounds: screenFrame),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let selection = candidates.reduce(CGRect.null) { $0.union($1.frame) }.intersection(screenFrame)
        guard !selection.isNull, selection.width > 0, selection.height > 0 else { return nil }
        return FrozenSelectionContext(screenFrame: screenFrame, localSelection: selection.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY), image: cgImage, isWindowComposition: true, backgroundImage: backgroundImage)
    }
    static func image(candidates: [FrozenWindowCandidate], images: [NSImage], screenFrame: CGRect) -> NSImage? {
        let bounds = candidates.reduce(CGRect.null) { $0.union($1.frame) }.intersection(screenFrame)
        return render(candidates: candidates, images: images, bounds: bounds)
    }
    private static func render(candidates: [FrozenWindowCandidate], images: [NSImage], bounds: CGRect) -> NSImage? {
        guard !candidates.isEmpty, candidates.count == images.count else { return nil }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
        let rasters = images.compactMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        guard rasters.count == images.count else { return nil }
        let scale = zip(rasters, images).map { CGFloat($0.width) / $1.size.width }.max() ?? 1
        let width = Int(ceil(bounds.width * scale)), height = Int(ceil(bounds.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(alpha: .premultipliedLast)) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // candidates are ordered front-to-back; draw in reverse so rear windows do not paint over front windows.
        for index in candidates.indices.reversed() {
            context.draw(rasters[index], in: candidates[index].frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY))
        }
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: bounds.size)
    }
}

enum FrozenSquareSelection {
    static func rect(from anchor: CGPoint, to point: CGPoint, within bounds: CGRect, square: Bool) -> CGRect {
        let point = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
        var dx = point.x - anchor.x, dy = point.y - anchor.y
        if square {
            let side = min(max(abs(dx), abs(dy)), dx < 0 ? anchor.x - bounds.minX : bounds.maxX - anchor.x,
                           dy < 0 ? anchor.y - bounds.minY : bounds.maxY - anchor.y)
            dx = dx < 0 ? -side : side; dy = dy < 0 ? -side : side
        }
        return CGRect(x: min(anchor.x, anchor.x + dx), y: min(anchor.y, anchor.y + dy), width: abs(dx), height: abs(dy)).intersection(bounds)
    }
}
