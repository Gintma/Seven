import ApplicationServices
import os

/// Runtime AX mode of the target app, not system TCC authorization; never reads titles, text, or input values.
enum FrozenSmartAccessibilityAttribute: String, CaseIterable, Sendable {
    case manual = "AXManualAccessibility"
    case enhanced = "AXEnhancedUserInterface"
}
protocol FrozenSmartAccessibilityAttributes: Sendable {
    func read(_ attribute: FrozenSmartAccessibilityAttribute, in pid: pid_t) -> Bool?
    @discardableResult
    func set(_ value: Bool, for attribute: FrozenSmartAccessibilityAttribute, in pid: pid_t) -> AXError
}
struct SystemFrozenSmartAccessibilityAttributes: FrozenSmartAccessibilityAttributes {
    private func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        return app
    }
    func read(_ attribute: FrozenSmartAccessibilityAttribute, in pid: pid_t) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application(pid), attribute.rawValue as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
    func set(_ value: Bool, for attribute: FrozenSmartAccessibilityAttribute, in pid: pid_t) -> AXError {
        // AppKit may return notImplemented even after changing the mode; callers must read back to verify rather than trusting the status code alone.
        AXUIElementSetAttributeValue(application(pid), attribute.rawValue as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
    }
}

/// A selection session owns on-demand AX mode activation; finishing immediately blocks new preparations and restores external state in the background.
/// Closing the screenshot overlay must not block on cross-process AX calls; callers can await the returned task to confirm restoration.
/// Prefers Electron's manual mode; never overwrites a mode that was already true and never guesses prior values of unreadable attributes.
struct FrozenSmartAccessibilitySession: Sendable {
    // Cold-started WebKit trees take ~2.6s to publish; apply this wait only during initial preparation without expanding per-query AX budgets.
    static let warmupTimeout: TimeInterval = 3
    static let warmupInterval: Duration = .milliseconds(100)
    private struct ModeChange: Sendable {
        let attribute: FrozenSmartAccessibilityAttribute
        // Electron may take several polling intervals after enabling before the readback reflects the updated value.
        let restoreWhilePending: Bool
    }
    private struct State: Sendable {
        var prepared: Set<pid_t> = []
        var changed: [pid_t: ModeChange] = [:]
    }
    // Prepare and restore in submission order so finish-then-prepare capture transitions remain serialized.
    // Independent overlapping sessions do not share attribute ownership and cannot guarantee mode lifecycle across arbitrary interleaving.
    // Call synchronous preparation only from background queries; finishing a session only enqueues restoration without waiting on this queue.
    private static let operations = DispatchQueue(label: "Seven.FrozenSmartAccessibility", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let cleanup = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private var isFinished: Bool { cleanup.withLock { $0 != nil } }
    private let attributes: any FrozenSmartAccessibilityAttributes
    private let restorations: FrozenSmartAccessibilityRestorations
    init(attributes: any FrozenSmartAccessibilityAttributes = SystemFrozenSmartAccessibilityAttributes(),
         restorations: FrozenSmartAccessibilityRestorations = .shared) {
        self.attributes = attributes
        self.restorations = restorations
    }
    /// Background thread only: blocks synchronously on the serial queue and cross-process AX; production callers enter via Task.detached.
    /// Returns true if this call actually enabled the mode, indicating the first query should wait for the target process to publish its internal tree.
    func prepare(_ pid: pid_t) -> Bool {
        Self.operations.sync { state.withLock { state in
            guard !isFinished, !restorations.isTerminating, state.prepared.insert(pid).inserted else { return false }
            for attribute in FrozenSmartAccessibilityAttribute.allCases {
                guard let previous = attributes.read(attribute, in: pid) else { continue }
                if previous || isFinished || restorations.isTerminating { return false }
                attributes.set(true, for: attribute, in: pid)
                if attributes.read(attribute, in: pid) == true {
                    state.changed[pid] = ModeChange(attribute: attribute, restoreWhilePending: false)
                    return true
                }
            }
            return false
        } }
    }

    /// Returns true only when this call issued an enable request, signaling the caller to wait for Electron to publish focus asynchronously.
    func requestManualAccessibility(_ pid: pid_t, report: (@Sendable (String) -> Void)? = nil) -> Bool {
        Self.operations.sync { state.withLock { state in
            guard !isFinished, !restorations.isTerminating, state.prepared.insert(pid).inserted else { return false }
            let previous = attributes.read(.manual, in: pid)
            report?("manual.before.\(Self.modeDescription(previous))")
            guard previous == false, !isFinished, !restorations.isTerminating else {
                return false
            }
            let status = attributes.set(true, for: .manual, in: pid)
            state.changed[pid] = ModeChange(attribute: .manual, restoreWhilePending: true)
            report?("manual.enable.\(status.rawValue)")
            return true
        } }
    }

    #if DEBUG || SEVEN_DEVELOPMENT
    func manualAccessibilityState(_ pid: pid_t) -> String {
        Self.operations.sync {
            guard !isFinished, !restorations.isTerminating else { return "ended" }
            return Self.modeDescription(attributes.read(.manual, in: pid))
        }
    }
    #endif

    private static func modeDescription(_ state: Bool?) -> String {
        guard let state else { return "unavailable" }
        return state ? "on" : "off"
    }

    @discardableResult
    func finish() -> Task<Void, Never> {
        cleanup.withLock { task in
            if let task { return task }
            let (completion, signal) = AsyncStream<Void>.makeStream()
            // Enqueue restoration immediately to preserve cross-session ordering without waiting for external IPC or an in-flight preparation.
            Self.operations.async {
                state.withLock { state in
                    for (pid, change) in state.changed {
                        if change.restoreWhilePending || attributes.read(change.attribute, in: pid) == true {
                            attributes.set(false, for: change.attribute, in: pid)
                        }
                    }
                    state.changed.removeAll(); state.prepared.removeAll()
                }
                signal.finish()
            }
            // Exposes only an awaitable completion signal; cancelling the waiter does not cancel restoration.
            let restoration = Task.detached(priority: .utility) { for await _ in completion {} }
            restorations.track(restoration)
            task = restoration
            return restoration
        }
    }
}
