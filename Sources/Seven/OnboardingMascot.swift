import AppKit
import SceneKit
import SwiftUI

struct MascotCue: Equatable {
    let reaction: OnboardingFlow.Reaction
    let direction: CGPoint
}

struct OnboardingMascot: NSViewRepresentable {
    let cue: MascotCue?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> OnboardingMascotView {
        OnboardingMascotView(icon: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
    }

    func updateNSView(_ view: OnboardingMascotView, context: Context) {
        view.reduceMotion = reduceMotion
        view.present(cue)
    }
}

@MainActor
final class OnboardingMascotView: NSView {
    private let portrait = ShibaPortrait()
    private weak var trackingView: NSView?
    private var tracking: NSTrackingArea?
    private var cue: MascotCue?
    private var pointerDirection = CGPoint.zero
    private var lastPointer: CGPoint?
    private var idleTask: Task<Void, Never>?
    private var tiltSide: CGFloat = 1
    var reduceMotion = false {
        didSet {
            guard oldValue != reduceMotion else { return }
            if reduceMotion {
                stopIdle()
                portrait.cancelExpression()
                look(toward: .zero, animated: false)
            }
            else { refreshPointer() }
        }
    }

    init(icon: NSImage) {
        super.init(frame: .zero)
        if let renderer = portrait.makeView() {
            addSubview(renderer)
        } else {
            let fallback = NSImageView(image: icon)
            fallback.imageScaling = .scaleProportionallyUpOrDown
            addSubview(fallback)
        }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stopIdle()
        if let tracking { trackingView?.removeTrackingArea(tracking) }
        tracking = nil
        trackingView = nil
        NotificationCenter.default.removeObserver(self)
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // SwiftUI may construct this view while NSWindow is still installing its contentView.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, tracking == nil,
                  let content = window.contentView else { return }
            let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow,
                .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag], owner: self, userInfo: nil)
            content.addTrackingArea(area)
            tracking = area
            trackingView = content
            NotificationCenter.default.addObserver(self, selector: #selector(refreshPointer),
                name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(rest),
                name: NSWindow.didResignKeyNotification, object: window)
            refreshPointer()
        }
    }

    override func mouseMoved(with event: NSEvent) { follow(event.locationInWindow) }
    override func mouseEntered(with event: NSEvent) { follow(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) {
        rest()
        scheduleIdle()
    }

    @objc private func refreshPointer() {
        guard let window, window.isKeyWindow else { return }
        let point = window.mouseLocationOutsideOfEventStream
        guard let content = window.contentView, content.bounds.contains(content.convert(point, from: nil)) else {
            rest()
            scheduleIdle()
            return
        }
        follow(point)
        scheduleIdle()
    }

    private func follow(_ point: NSPoint) {
        guard !reduceMotion, bounds.width > 0 else { return }
        let local = convert(point, from: nil)
        if lastPointer.map({ hypot($0.x - local.x, $0.y - local.y) > 2 }) ?? true {
            lastPointer = local
            scheduleIdle()
        }
        let dx = local.x - bounds.midX
        let dy = local.y - bounds.height * (1 - 152.0 / 320)
        let distance = max(bounds.width * 0.7, hypot(dx, dy))
        look(toward: CGPoint(x: dx / distance, y: dy / distance), animated: true)
    }

    @objc private func rest() {
        stopIdle()
        lastPointer = nil
        look(toward: .zero, animated: !reduceMotion)
    }

    private func stopIdle() {
        idleTask?.cancel()
        idleTask = nil
        portrait.stopIdleTilt()
    }

    private func scheduleIdle() {
        stopIdle()
        guard cue == nil, !reduceMotion, window?.isKeyWindow == true else { return }
        idleTask = makeIdleTask()
    }

    func makeIdleTask() -> Task<Void, Never> {
        Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2.4))
                while !Task.isCancelled, self != nil {
                    self?.portrait.blink()
                    try await Task.sleep(for: .seconds(2.8))
                    guard self != nil else { return }
                    self?.tiltDuringIdle()
                    try await Task.sleep(for: .seconds(3.6))
                }
            } catch {}
        }
    }

    private func tiltDuringIdle() {
        portrait.tilt(tiltSide)
        tiltSide *= -1
    }

    func present(_ next: MascotCue?) {
        guard next != cue else { return }
        cue = next
        stopIdle()
        portrait.cancelExpression()
        guard !reduceMotion else { return }
        guard let next else {
            portrait.look(toward: pointerDirection, animated: true)
            scheduleIdle()
            return
        }
        switch next.reaction {
        case .login: portrait.blink()
        case .accessibility, .screenRecording:
            portrait.look(toward: next.direction, animated: true)
            portrait.nod()
        }
    }

    private func look(toward direction: CGPoint, animated: Bool) {
        pointerDirection = direction
        if animated, let cue, cue.reaction != .login { return }
        portrait.look(toward: direction, animated: animated)
    }
}
