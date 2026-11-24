import AppKit

/// 自身 UI 只读已布局的原生视图几何；不进入 SwiftUI 虚拟辅助功能回调。
@MainActor enum FrozenNativeSmartSelection {
    static func query(at point: CGPoint, in candidate: FrozenWindowCandidate, geometry: FrozenSmartGeometry) -> FrozenSmartSelectionResult {
        guard let window = NSApp.windows.first(where: { $0.windowNumber == Int(candidate.id) }) else { return FrozenSmartSelectionResult() }
        let reader = FrozenNativeSmartReader(window: window, geometry: geometry)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.05
        return FrozenSmartTree(reader: reader).query(at: point, in: candidate.frame,
            withinBudget: { ProcessInfo.processInfo.systemUptime < deadline })
    }
}

private struct FrozenNativeSmartNode: Hashable {
    let object: NSObject
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.object === rhs.object }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(object)) }
}

/// 此私有桥接只由上面的 MainActor 同步入口构造、读取，不跨线程传递 UI 对象。
@MainActor private struct FrozenNativeSmartReader: @preconcurrency FrozenSmartTreeReading {
    let window: NSWindow
    let geometry: FrozenSmartGeometry
    func windows() -> [FrozenNativeSmartNode] { [FrozenNativeSmartNode(object: window)] }
    // 从真实子视图和显式布局锚点遍历，不能在主线程调用 accessibilityHitTest。
    func hit(at point: CGPoint) -> FrozenNativeSmartNode? { nil }
    func role(_ value: FrozenNativeSmartNode) -> String? {
        if value.object is NSWindow { return "AXWindow" }
        if let anchor = value.object as? SettingsSmartSelectionAnchor { return anchor.smartRole }
        // 只按原生控件类型分类，不查询可能执行 SwiftUI 代码的 accessibilityRole。
        switch value.object {
        case is NSPopUpButton: return "AXPopUpButton"
        case is NSComboBox: return "AXComboBox"
        case is NSButton: return "AXButton"
        case is NSSwitch: return "AXSwitch"
        case is NSSegmentedControl: return "AXRadioGroup"
        case is NSSlider: return "AXSlider"
        case is NSColorWell: return "AXColorWell"
        case is NSStepper: return "AXIncrementor"
        case is NSProgressIndicator: return "AXProgressIndicator"
        case is NSScroller: return "AXScrollBar"
        case let field as NSTextField: return field.isEditable ? "AXTextField" : "AXStaticText"
        case is NSTextView: return "AXTextArea"
        case is NSImageView: return "AXImage"
        case is NSScrollView: return "AXScrollArea"
        case is NSOutlineView: return "AXOutline"
        case is NSTableView: return "AXTable"
        case is NSTableRowView: return "AXRow"
        case is NSTableCellView: return "AXCell"
        case is NSSplitView: return "AXSplitGroup"
        default: return value.object is NSView ? "AXGroup" : nil
        }
    }
    func frame(_ value: FrozenNativeSmartNode) -> CGRect? {
        if let window = value.object as? NSWindow { return geometry.rect(window.frame) }
        guard let view = value.object as? NSView, let window = view.window else { return nil }
        return geometry.rect(window.convertToScreen(view.convert(view.bounds, to: nil)))
    }
    func children(_ value: FrozenNativeSmartNode) -> [FrozenNativeSmartNode] {
        let views = (value.object as? NSView)?.subviews ?? (value.object as? NSWindow)?.contentView.map { [$0] } ?? []
        return views.filter { !$0.isHiddenOrHasHiddenAncestor }.map { FrozenNativeSmartNode(object: $0) }
    }
    func parent(_ value: FrozenNativeSmartNode) -> FrozenNativeSmartNode? {
        guard let view = value.object as? NSView else { return nil }
        if let parent = view.superview { return FrozenNativeSmartNode(object: parent) }
        return view.window.map { FrozenNativeSmartNode(object: $0) }
    }
}
