import ApplicationServices
import os

/// 目标应用的运行时AX模式，不是系统授权；不读取标题、文字或输入值。
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
        // AppKit可能返回notImplemented，但实际已改变模式；由调用者回读确认，不能只看返回码。
        AXUIElementSetAttributeValue(application(pid), attribute.rawValue as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
    }
}

/// 一个选区会话持有按需开启的AX模式；结束立即禁止新准备，后台恢复外部状态。
/// 截图遮罩的关闭不能等待跨进程AX调用，调用者可等待返回任务确认恢复完成。
/// 优先使用Electron的manual模式；不覆盖原先为true的模式、不猜测不可读取属性的旧值。
struct FrozenSmartAccessibilitySession: Sendable {
    // 实际冷启动的WebKit树约2.6秒才发布；只用于首次准备，不扩大单次AX查询预算。
    static let warmupTimeout: TimeInterval = 3
    static let warmupInterval: Duration = .milliseconds(100)
    private struct ModeChange: Sendable {
        let attribute: FrozenSmartAccessibilityAttribute
        // Electron 可能在提交启用请求几个轮询周期后才更新读值。
        let restoreWhilePending: Bool
    }
    private struct State: Sendable {
        var prepared: Set<pid_t> = []
        var changed: [pid_t: ModeChange] = [:]
    }
    // 按提交顺序准备/恢复；先finish再prepare的截图切换保持顺序。
    // 独立且重叠的会话不共享属性所有权，不能据此保证任意交错下的模式生命周期。
    // 只从后台查询调用同步准备；结束会话仅入队，不等待此队列。
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
    /// 仅限后台线程调用：同步等待串行队列和跨进程AX；生产入口在Task.detached。
    /// 返回true表示本次确实开启了模式，首次查询需要等目标进程发布内部树。
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

    /// 仅在本次发出开启请求时返回 true，让调用方等待 Electron 异步发布焦点。
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
            // 立即提交恢复以保证跨会话顺序，不等待外部调用或正在执行的准备。
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
            // 仅提供可等待的完成信号，取消查询不会取消恢复。
            let restoration = Task.detached(priority: .utility) { for await _ in completion {} }
            restorations.track(restoration)
            task = restoration
            return restoration
        }
    }
}
