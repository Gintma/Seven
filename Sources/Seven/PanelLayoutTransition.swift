import AppKit
import QuartzCore

/// The only owner of animated layout heights. New targets continue from current heights.
@MainActor
final class PanelLayoutTransition {
    private struct Track {
        let constraint: NSLayoutConstraint
        let start: CGFloat
        let target: CGFloat
    }
    private var tracks: [ObjectIdentifier: Track] = [:]
    private var timer: Timer?
    private var startedAt: CFTimeInterval = 0
    private var duration: TimeInterval = 0
    private var completions: [() -> Void] = []
    var onFrame: (() -> Void)?
    var isActive: Bool { timer != nil }

    func update(
        changes: [(NSLayoutConstraint, CGFloat)],
        duration: TimeInterval,
        completion: (() -> Void)? = nil
    ) {
        if let completion { completions.append(completion) }
        guard !changes.isEmpty else {
            onFrame?()
            if !isActive { finish() }
            return
        }
        var targets = tracks.mapValues { ($0.constraint, $0.target) }
        for (constraint, target) in changes {
            targets[ObjectIdentifier(constraint)] = (constraint, target)
        }
        tracks = targets.mapValues { constraint, target in
            Track(constraint: constraint, start: constraint.constant, target: target)
        }
        self.duration = duration
        startedAt = CACurrentMediaTime()
        guard duration > 0 else {
            for track in tracks.values { track.constraint.constant = track.target }
            onFrame?()
            finish()
            return
        }
        onFrame?()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.tick()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        let t = min(1, (CACurrentMediaTime() - startedAt) / duration)
        let eased = CGFloat(t * t * (3 - 2 * t))
        for track in tracks.values {
            track.constraint.constant = track.start + (track.target - track.start) * eased
        }
        onFrame?()
        if t >= 1 { finish() }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        tracks.removeAll()
        let callbacks = completions
        completions.removeAll()
        for callback in callbacks { callback() }
    }
}
