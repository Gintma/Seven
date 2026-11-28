import AppKit
import ApplicationServices

/// Reads structure, roles, and bounds only; never reads titles, text, or input values, and never performs control actions.
/// Requests the target app to expose its full AX tree per session when needed, and restores the prior state afterward.
protocol FrozenSmartSelecting: Sendable {
    func finishSession()
    func regions(at point: CGPoint, in window: FrozenWindowCandidate, geometry: FrozenSmartGeometry) async -> FrozenSmartSelectionResult
}

extension FrozenSmartSelecting { func finishSession() {} }

/// Seven's own windows use laid-out native geometry only; never issue system AX queries against our own PID.
struct SystemFrozenSmartSelection: FrozenSmartSelecting {
    private let remote: any FrozenSmartSelecting
    init(remote: any FrozenSmartSelecting = SystemFrozenRemoteSmartSelection()) { self.remote = remote }
    func finishSession() { remote.finishSession() }
    func regions(at point: CGPoint, in window: FrozenWindowCandidate, geometry: FrozenSmartGeometry) async -> FrozenSmartSelectionResult {
        if window.ownerPID == ProcessInfo.processInfo.processIdentifier {
            return await MainActor.run {
                FrozenNativeSmartSelection.query(at: point, in: window, geometry: geometry)
            }
        }
        return await remote.regions(at: point, in: window, geometry: geometry)
    }
}
