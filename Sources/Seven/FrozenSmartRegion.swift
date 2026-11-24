import AppKit

/// 无障碍结构的几何快照，仅在当前截图会话内使用。
struct FrozenSmartRegion: Equatable, Sendable {
    let role: String
    let frame: CGRect
    var isTextBlock = false

    static let controls: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXComboBox", "AXTextField", "AXTextArea", "AXSlider", "AXSwitch", "AXDisclosureTriangle",
        "AXIncrementor", "AXColorWell", "AXLink", "AXDateField", "AXTimeField",
        "AXMenuItem", "AXMenuBarItem", "AXProgressIndicator", "AXBusyIndicator"]
    static let containers: Set<String> = ["AXGroup", "AXScrollArea", "AXSplitGroup", "AXTable", "AXList", "AXOutline",
        "AXTabGroup", "AXRadioGroup", "AXToolbar", "AXWebArea", "AXLayoutArea", "AXLayoutItem", "AXPopover",
        "AXMenu", "AXMenuBar", "AXGrid", "AXBrowser", "AXUnknown", "AXSheet", "AXDialog", "AXSystemDialog", "AXDrawer"]
    static let surfaces:Set<String> = ["AXWindow", "AXSheet", "AXDialog", "AXSystemDialog", "AXDrawer", "AXPopover"]
    static let textBlocks:Set<String> = ["AXParagraph", "AXHeading", "AXListItem", "AXBlockQuote", "AXCode"]
    static let selectable = controls.union(containers).union(textBlocks).union(["AXStaticText", "AXRow", "AXCell", "AXImage", "AXScrollBar"])
    var isText:Bool {role == "AXStaticText" || Self.textBlocks.contains(role) || isTextBlock}
    var ownsLabel:Bool {Self.controls.contains(role) || role == "AXRow" || role == "AXCell"}
    var hasValidFrame:Bool {!frame.isNull && !frame.isInfinite && area.isFinite && frame.minX.isFinite && frame.minY.isFinite && frame.maxX.isFinite && frame.maxY.isFinite && frame.width>0 && frame.height>0}
    /// 识别规则的容差，不改变界面尺寸。
    static let manualSelectionResetDistance: CGFloat = 3
    static let windowMatchTolerance: CGFloat = 4

    var priority: Int {
        if role == "AXScrollBar" { return 0 }
        if Self.controls.contains(role) { return 1 }
        if role == "AXRow" { return 2 }
        if role == "AXCell" { return 3 }
        if role == "AXImage" || Self.textBlocks.contains(role) || isTextBlock { return 4 }
        if role == "AXStaticText" {return 5}
        return 6
    }
    var isTerminal: Bool { priority <= 1 || role == "AXImage" }
    var isContainer: Bool { Self.containers.contains(role) && !isTextBlock }
    var area: CGFloat { frame.width * frame.height }
    static func matchesWindow(_ rect: CGRect, _ target: CGRect) -> Bool {
        abs(rect.minX - target.minX) <= windowMatchTolerance && abs(rect.minY - target.minY) <= windowMatchTolerance
            && abs(rect.maxX - target.maxX) <= windowMatchTolerance && abs(rect.maxY - target.maxY) <= windowMatchTolerance
    }
    /// 只有真实视口裁剪子控件，普通分组的内容边界不能削掉输入框等控件的边框。
    static func candidates(at point: CGPoint?, in window: CGRect, ancestry: [Self]) -> [Self] {
        var viewport = window
        var result: [Self] = []
        for region in ancestry.reversed() {
            let rect = region.frame
            guard region.hasValidFrame else {continue}
            let clipped = rect.intersection(viewport)
            if selectable.contains(region.role), !clipped.isEmpty,
               point.map(clipped.contains) ?? true, !matchesWindow(clipped, window) {
                result.append(Self(role:region.role,frame:clipped,isTextBlock:region.isTextBlock))
            }
            if region.role == "AXScrollArea" || Self.surfaces.contains(region.role) { viewport = clipped }
        }
        let path=Array(result.reversed())
        // 子标签不拆散真实控件/整行；段落的文字碎片归属于其紧贴内容的容器。
        let owned=path.enumerated().filter {index,region in
            !path.dropFirst(index+1).contains {parent in
                guard parent.frame.contains(region.frame) else{return false}
                return (parent.ownsLabel && region.isText)
                    || (Self.controls.contains(parent.role) && ["AXImage","AXProgressIndicator","AXBusyIndicator"].contains(region.role))
                    || (parent.isText && parent.role != "AXStaticText" && region.role == "AXStaticText")
            }
        }.map(\.element)
        // 多层同框包装只提供一个层级；使用同框中语义最明确的对象。
        var unique:[Self]=[]
        for region in owned {
            if let index=unique.firstIndex(where:{$0.frame == region.frame}) {
                if region.precedes(unique[index]) {unique[index]=region}
            } else {unique.append(region)}
        }
        return unique
    }
    func precedes(_ other:Self)->Bool {priority == other.priority ? area<other.area:priority<other.priority}
    static func preferred(_ candidates: [Self]) -> Self? {
        candidates.min {$0.precedes($1)}
    }
    static func selection(at point: CGPoint, in window: CGRect, ancestry: [Self]) -> CGRect? {
        preferred(candidates(at: point, in: window, ancestry: ancestry))?.frame
    }
}

/// 留住已确认的父面板，在控件间的空隙里选择包含鼠标的面板。
struct FrozenSmartSelectionCache {
    private struct Entry {
        let window: FrozenWindowCandidate
        var regions: [FrozenSmartRegion] = []
    }
    private var known: [CGWindowID: Entry] = [:]
    func hierarchy(at point:CGPoint,in window:FrozenWindowCandidate)->[FrozenSmartRegion] {
        let regions=known[window.id].flatMap {$0.window == window ? $0.regions:nil} ?? []
        let sorted=regions.filter{$0.frame.contains(point)}.sorted {
            $0.area == $1.area ? $0.priority < $1.priority:$0.area < $1.area
        }
        var chain:[FrozenSmartRegion]=[]
        for region in sorted {
            if let last=chain.last,(!region.frame.contains(last.frame) || region.frame==last.frame) {continue}
            chain.append(region)
        }
        if chain.last?.frame != window.frame {chain.append(FrozenSmartRegion(role:"AXWindow",frame:window.frame))}
        return chain
    }
    func element(at point: CGPoint, in window: FrozenWindowCandidate) -> FrozenSmartRegion? {
        guard let entry = known[window.id], entry.window == window else { return nil }
        return FrozenSmartRegion.preferred(entry.regions.filter { !$0.isContainer && $0.frame.contains(point) })
    }
    mutating func target(at point: CGPoint, in window: FrozenWindowCandidate, result: FrozenSmartSelectionResult,
                         retaining current: FrozenSmartRegion? = nil) -> FrozenSmartRegion? {
        let sameWindow = known[window.id]?.window == window
        if !sameWindow { known[window.id] = Entry(window: window) }
        let fresh = FrozenSmartRegion.candidates(at: point, in: window.frame, ancestry: result.ancestry)
        for region in fresh + result.siblings where region.hasValidFrame && region.frame.intersects(window.frame) {
            let clipped=FrozenSmartRegion(role:region.role,frame:region.frame.intersection(window.frame),isTextBlock:region.isTextBlock)
            guard !FrozenSmartRegion.matchesWindow(clipped.frame,window.frame) else{continue}
            if !(known[window.id]?.regions ?? []).contains(clipped) {known[window.id]?.regions.append(clipped)}
        }
        if let element = FrozenSmartRegion.preferred(fresh), !element.isContainer { return element }
        if let element = element(at: point, in: window) { return element }
        let parents = (known[window.id]?.regions ?? []).filter { $0.isContainer && $0.frame.contains(point) }
        let parent = FrozenSmartRegion.preferred(fresh + parents)
        if sameWindow, let current, current.frame.contains(point), parent == nil || parent?.frame.contains(current.frame) == true { return current }
        return parent
    }
}
