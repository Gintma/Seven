import AppKit
import ScreenCaptureKit

@MainActor
struct SystemFrozenScreenshotCapture: FrozenScreenshotCapturing {
    private struct Screen {
        let id: CGDirectDisplayID
        let frame: CGRect
        let width: Int
        let height: Int

        init(_ screen: NSScreen) throws {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                throw ScreenshotTranslationError.captureFailed
            }
            id = number.uint32Value
            frame = screen.frame
            width = Int((frame.width * screen.backingScaleFactor).rounded())
            height = Int((frame.height * screen.backingScaleFactor).rounded())
        }
    }

    func freezeScreens() async throws -> [FrozenScreenshotFrame] {
        let started = ProcessInfo.processInfo.systemUptime
        let screens = try NSScreen.screens.map(Screen.init)
        guard !screens.isEmpty else { throw ScreenshotTranslationError.captureFailed }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let displays = try screens.map { screen in
            guard let display = content.displays.first(where: { $0.displayID == screen.id }) else {
                throw ScreenshotTranslationError.captureFailed
            }
            return display
        }

        let frames = try await withThrowingTaskGroup(of: (Int, FrozenScreenshotFrame).self) { group in
            for (index, (screen, display)) in zip(screens, displays).enumerated() {
                group.addTask { @MainActor in
                    try Task.checkCancellation()
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let configuration = SCStreamConfiguration()
                    configuration.width = screen.width
                    configuration.height = screen.height
                    configuration.captureResolution = .best
                    configuration.showsCursor = false
                    configuration.capturesAudio = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                    try Task.checkCancellation()
                    return (index, FrozenScreenshotFrame(screenFrame: screen.frame, image: image))
                }
            }
            var ordered = [FrozenScreenshotFrame?](repeating: nil, count: screens.count)
            for try await (index, frame) in group { ordered[index] = frame }
            return ordered.compactMap { $0 }
        }

        try Task.checkCancellation()
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        let sizes = frames.map { "\($0.image.width)x\($0.image.height)" }.joined(separator: ",")
        Task {
            await FileDiagnosticLogger.shared.record(.info, "screenshot_freeze_succeeded", metadata: [
                "elapsed_ms": String(elapsed),
                "screen_sizes_px": sizes
            ])
        }
        return frames
    }
}
