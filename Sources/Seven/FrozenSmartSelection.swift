import AppKit
import ApplicationServices

/// 读取结构、角色与边界，不读取标题、文本、输入值或执行控件动作。
/// 必要时按会话请求目标应用发布完整AX树，结束后恢复原状态。
protocol FrozenSmartSelecting: Sendable {
    func finishSession()
    func regions(at point: CGPoint, in window: FrozenWindowCandidate, geometry: FrozenSmartGeometry) async -> FrozenSmartSelectionResult
}

extension FrozenSmartSelecting { func finishSession() {} }

/// 自身窗口只走已布局的原生几何；不能再对自己的 PID 发系统 AX 查询。
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
