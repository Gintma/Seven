import AppKit
import ApplicationServices

/// 外部应用的系统 AX 查询保持在后台线程；自身窗口不进入此实现。
struct SystemFrozenRemoteSmartSelection: FrozenSmartSelecting {
    private let accessibility = FrozenSmartAccessibilitySession()
    func finishSession() { accessibility.finish() }
    func regions(at point: CGPoint, in window: FrozenWindowCandidate, geometry: FrozenSmartGeometry) async -> FrozenSmartSelectionResult {
        let fallback = FrozenSmartSelectionResult()
        let worker = Task.detached(priority: .userInitiated) { [accessibility] in
            guard AXIsProcessTrusted() else { return fallback }
            guard let pid = window.ownerPID else { return FrozenSmartSelectionResult() }
            let needsWarmup = accessibility.prepare(pid)
            let warmupDeadline = ProcessInfo.processInfo.systemUptime + FrozenSmartAccessibilitySession.warmupTimeout
            let reader = FrozenSmartAXReader(app: AXUIElementCreateApplication(pid), geometry: geometry)
            var result = FrozenSmartSelectionResult(), remote: CGRect?
            repeat {
                guard !Task.isCancelled else { return fallback }
                let deadline = ProcessInfo.processInfo.systemUptime + 0.2
                result = FrozenSmartTree(reader: reader).query(at: point, in: window.frame,
                    withinBudget: { !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline })
                remote = FrozenSmartRegion.selection(at: point, in: window.frame, ancestry: result.ancestry)
                // 只有首次实际开启懒加载AX树时等待，不改变已就绪后的悬停节奏或查询预算。
                if remote != nil || result.ancestry.contains(where: { $0.role == "AXWebArea" }) || !needsWarmup || ProcessInfo.processInfo.systemUptime >= warmupDeadline { break }
                do { try await Task.sleep(for: FrozenSmartAccessibilitySession.warmupInterval) }
                catch { return fallback }
            } while !Task.isCancelled
            return remote != nil ? result : fallback
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
}

private struct FrozenSmartAXNode: Hashable {
    let value: AXUIElement
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.value, rhs.value) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(value)) }
}

private struct FrozenSmartAXReader: FrozenSmartTreeReading {
    let app: AXUIElement
    let geometry: FrozenSmartGeometry
    func windows() -> [FrozenSmartAXNode] { elements(kAXWindowsAttribute, app) }
    func children(_ node: FrozenSmartAXNode) -> [FrozenSmartAXNode] {
        let direct = elements(kAXChildrenAttribute, node.value)
        return direct.isEmpty ? elements("AXChildrenInNavigationOrder", node.value) : direct
    }
    func parent(_ node: FrozenSmartAXNode) -> FrozenSmartAXNode? {
        guard let value = attribute(kAXParentAttribute, node.value), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return FrozenSmartAXNode(value: unsafeBitCast(value, to: AXUIElement.self))
    }
    func role(_ node: FrozenSmartAXNode) -> String? { attribute(kAXRoleAttribute, node.value) as? String }
    func frame(_ node: FrozenSmartAXNode) -> CGRect? {
        guard let position = attribute(kAXPositionAttribute, node.value), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(kAXSizeAttribute, node.value), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &p),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &s) else { return nil }
        return geometry.rect(CGRect(x: p.x, y: geometry.primaryScreenTop - p.y - s.height, width: s.width, height: s.height))
    }
    func hit(at point: CGPoint) -> FrozenSmartAXNode? {
        AXUIElementSetMessagingTimeout(app, 0.05)
        var element: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(geometry.primaryScreenTop - point.y), &element)
        return status == .success ? element.map { FrozenSmartAXNode(value: $0) } : nil
    }
    private func elements(_ name: String, _ element: AXUIElement) -> [FrozenSmartAXNode] {
        (attribute(name, element) as? [AXUIElement] ?? []).map { FrozenSmartAXNode(value: $0) }
    }
    private func attribute(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.05)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return status == .success ? value : nil
    }
}
