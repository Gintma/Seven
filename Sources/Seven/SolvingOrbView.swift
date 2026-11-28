import AppKit

/// Runs only while the status pill is visible and loading; immediately releases the timer when hidden, stopped, or removed from the window.
@MainActor
final class SolvingOrbView: ThemedDrawingView {
    private var timer: Timer?
    private var startedAt: TimeInterval = 0
    private(set) var isAnimating = false
    var isTicking: Bool { timer != nil }
    private var motionObserver: NSObjectProtocol?
    var onFrame: (() -> Void)?
    var onMotionChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateClock(); self?.onMotionChange?() }
        }
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        timer?.invalidate()
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
    }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isHidden: Bool { didSet { updateClock() } }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateClock() }
    func startAnimation(_ sender: Any?) {
        if !isAnimating { startedAt = ProcessInfo.processInfo.systemUptime }
        isAnimating = true
        updateClock()
    }
    func stopAnimation(_ sender: Any?) { isAnimating = false; updateClock() }
    private func updateClock() {
        timer?.invalidate(); timer = nil
        needsDisplay = true
        guard isAnimating, window != nil, !isHidden, !Design.Motion.reduced else { return }
        let clock = Timer(timeInterval: Design.ReplacementHUD.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true; self?.onFrame?() }
        }
        RunLoop.main.add(clock, forMode: .common)
        timer = clock
    }
    override func draw(_ dirtyRect: NSRect) {
        let elapsed = Design.Motion.reduced ? 0 : ProcessInfo.processInfo.systemUptime - startedAt
        let side = min(bounds.width, bounds.height)
        let dots = SolvingOrbGeometry.dots(size: side, elapsed: elapsed)
        for dot in dots {
            let weight = min(1, max(0, 1 - dot.white))
            theme.hudText.withAlphaComponent(weight).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - side / 2 + dot.x - dot.r,
                                      y: bounds.midY - side / 2 + dot.y - dot.r,
                                      width: dot.r * 2, height: dot.r * 2)).fill()
        }
    }
}
