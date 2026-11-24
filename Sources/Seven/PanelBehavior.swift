import AppKit
import Carbon

struct OperationGate {
    private(set) var current: UUID?

    mutating func begin() -> UUID {
        let token = UUID()
        current = token
        return token
    }

    func accepts(_ token: UUID) -> Bool {
        current == token
    }

    @discardableResult
    mutating func finish(_ token: UUID) -> Bool {
        guard current == token else { return false }
        current = nil
        return true
    }

    mutating func invalidate() {
        current = nil
    }
}

enum PanelGeometry {
    /// 跟随鼠标时，窗口从指针处向右下展开，超出可视区域时向内收回。
    /// 左、右、下各留 `margin`，顶部不留（`visibleFrame` 已避开菜单栏）。
    /// 有选区时，只有这样摆会挡住选区，才在选区四周另找重叠最少的位置。
    static func frame(
        around anchor: NSPoint,
        size proposedSize: NSSize,
        within visibleFrame: NSRect,
        avoiding exclusionRect: NSRect? = nil,
        margin: CGFloat = 10,
        gap: CGFloat = 14
    ) -> NSRect {
        let permittedFrame = NSRect(
            x: visibleFrame.minX + margin,
            y: visibleFrame.minY + margin,
            width: max(1, visibleFrame.width - margin * 2),
            height: max(1, visibleFrame.height - margin)
        )
        let size = NSSize(
            width: min(proposedSize.width, permittedFrame.width),
            height: min(proposedSize.height, permittedFrame.height)
        )
        let preferredFrame = roundedOrigin(NSRect(
            x: clamp(anchor.x, lower: permittedFrame.minX, upper: permittedFrame.maxX - size.width),
            y: clamp(anchor.y - size.height, lower: permittedFrame.minY, upper: permittedFrame.maxY - size.height),
            width: size.width,
            height: size.height
        ))
        guard let exclusionRect, !exclusionRect.isEmpty, preferredFrame.intersects(exclusionRect) else {
            return preferredFrame
        }

        let protectedRect = exclusionRect.insetBy(dx: -gap, dy: -gap)
        let candidates = [
            NSPoint(x: protectedRect.maxX, y: anchor.y - size.height),
            NSPoint(x: protectedRect.minX - size.width, y: anchor.y - size.height),
            NSPoint(x: anchor.x, y: protectedRect.minY - size.height),
            NSPoint(x: anchor.x, y: protectedRect.maxY),
            preferredFrame.origin
        ].map { origin in
            roundedOrigin(NSRect(
                x: clamp(origin.x, lower: permittedFrame.minX, upper: permittedFrame.maxX - size.width),
                y: clamp(origin.y, lower: permittedFrame.minY, upper: permittedFrame.maxY - size.height),
                width: size.width,
                height: size.height
            ))
        }

        return candidates.enumerated().min { lhs, rhs in
            score(lhs.element, protectedRect: protectedRect, preferredFrame: preferredFrame, order: lhs.offset)
                < score(rhs.element, protectedRect: protectedRect, preferredFrame: preferredFrame, order: rhs.offset)
        }?.element ?? preferredFrame
    }

    static func frameKeepingTop(
        _ currentFrame: NSRect,
        height proposedHeight: CGFloat,
        within visibleFrame: NSRect,
        margin: CGFloat = 12
    ) -> NSRect {
        let availableWidth = max(1, visibleFrame.width - margin * 2)
        let availableHeight = max(1, visibleFrame.height - margin * 2)
        let size = NSSize(
            width: min(currentFrame.width, availableWidth),
            height: min(max(1, proposedHeight), availableHeight)
        )
        let minimumX = visibleFrame.minX + margin
        let maximumX = visibleFrame.maxX - margin - size.width
        let minimumY = visibleFrame.minY + margin
        let maximumY = visibleFrame.maxY - margin - size.height
        let origin = NSPoint(
            x: clamp(currentFrame.minX, lower: minimumX, upper: maximumX),
            y: clamp(currentFrame.maxY - size.height, lower: minimumY, upper: maximumY)
        )
        return NSRect(origin: origin, size: size)
    }

    /// 回到上次的位置：保持左边与顶边，只按内容调整高度。
    /// 放在与上次窗口重叠最多的屏幕上；该屏幕已断开时移到 `fallback` 屏幕内。
    static func rememberedFrame(
        _ lastFrame: NSRect,
        height: CGFloat,
        screens visibleFrames: [NSRect],
        fallback: NSRect
    ) -> NSRect {
        return frameKeepingTop(lastFrame, height: height, within: screen(mostOverlapping: lastFrame, in: visibleFrames) ?? fallback)
    }

    /// 与 `frame` 重叠面积最大的屏幕；都不重叠时返回 nil。
    static func screen(mostOverlapping frame: NSRect, in visibleFrames: [NSRect]) -> NSRect? {
        var best: NSRect?
        var bestArea: CGFloat = 0
        for candidate in visibleFrames {
            let overlap = candidate.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                best = candidate
                bestArea = area
            }
        }
        return best
    }

    /// 只把原点取整，宽高保持不变。`NSRect.integral` 会向外取整，
    /// 鼠标坐标带小数时每次弹出都让宽度多 1。
    private static func roundedOrigin(_ rect: NSRect) -> NSRect {
        NSRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: rect.width, height: rect.height)
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard upper >= lower else { return lower }
        return min(max(value, lower), upper)
    }

    private static func score(
        _ frame: NSRect,
        protectedRect: NSRect,
        preferredFrame: NSRect,
        order: Int
    ) -> (CGFloat, CGFloat, Int) {
        let intersection = frame.intersection(protectedRect)
        let overlap = intersection.isNull ? 0 : intersection.width * intersection.height
        let displacement = hypot(frame.midX - preferredFrame.midX, frame.midY - preferredFrame.midY)
        return (overlap, displacement, order)
    }
}

enum PanelManualResizePolicy {
    static func widthOnly(proposed: NSSize, current: NSSize) -> NSSize {
        NSSize(width: proposed.width, height: current.height)
    }
}

enum OverlayScrollerPolicy {
    static func configure(_ scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScroller?.controlSize = .mini
    }
}

enum PanelKeyboardAction: Equatable {
    case translate
    case insertNewline
    case retry
    case togglePin
    case close
}

enum PanelKeyboardRouter {
    static func action(
        keyCode: UInt16,
        modifiers rawModifiers: NSEvent.ModifierFlags,
        isEditingText: Bool,
        hasMarkedText: Bool = false
    ) -> PanelKeyboardAction? {
        let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let modifiers = rawModifiers.intersection(relevantModifiers)
        let commandOnly = modifiers == .command

        if commandOnly && keyCode == UInt16(kVK_ANSI_R) { return .retry }
        if commandOnly && keyCode == UInt16(kVK_ANSI_P) { return .togglePin }
        if commandOnly && keyCode == UInt16(kVK_ANSI_W) { return .close }
        let isReturn = keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter)
        if isEditingText && hasMarkedText,
           isReturn || keyCode == UInt16(kVK_Escape) {
            return nil
        }
        if modifiers.isEmpty && keyCode == UInt16(kVK_Escape) { return .close }

        guard isReturn else { return nil }
        if isEditingText && (modifiers.contains(.command) || modifiers.contains(.shift)) {
            return .insertNewline
        }
        if modifiers.isEmpty { return .translate }
        return nil
    }
}

enum ServiceResultPresentationPolicy {
    static func visibleExpanded(
        persistedExpanded: Bool,
        phase: TranslationResultPhase
    ) -> Bool {
        persistedExpanded && phase != .idle
    }

    static func showsBody(
        visibleExpanded: Bool,
        hasCurrentResult: Bool,
        clearTransitionActive: Bool,
        phase: TranslationResultPhase
    ) -> Bool {
        !clearTransitionActive
            && visibleExpanded
            && hasCurrentResult
            && phase != .loading
            && phase != .idle
    }
}

enum TranslationWindowLayoutPreferences {
    static let minimumInputMaximumHeight = 120
    static let maximumInputMaximumHeight = 480
    static let inputMaximumHeightStep = 10
    static let defaultInputMaximumHeight = 180
    static let minimumWindowHeightRatio = 0.50
    static let maximumWindowHeightRatio = 0.95
    static let maximumWindowHeightRatioStep = 0.01
    static let defaultMaximumWindowHeightRatio = 0.60
    /// 窗口高度始终贴合内容（用户只能横向拉伸），这里只防极端情况；
    /// 原先的 300 会让只有 0～1 张卡片时底部留出大片空白。
    static let minimumPanelHeight: CGFloat = 120
    /// “最大窗口高度”的下限，避免小屏幕上上限被算得过小。
    static let smallestMaximumPanelHeight: CGFloat = 300
    /// 紧凑工具栏样式下的标题栏高度（见 App.swift 中的 toolbarStyle）。
    static let titlebarHeightAllowance: CGFloat = 40

    static func normalizedInputMaximumHeight(_ value: Int) -> Int {
        let clamped = min(max(value, minimumInputMaximumHeight), maximumInputMaximumHeight)
        return Int(
            (Double(clamped) / Double(inputMaximumHeightStep)).rounded()
                * Double(inputMaximumHeightStep)
        )
    }

    static func normalizedMaximumWindowHeightRatio(_ value: Double) -> Double {
        guard value.isFinite else { return defaultMaximumWindowHeightRatio }
        let clamped = min(max(value, minimumWindowHeightRatio), maximumWindowHeightRatio)
        let stepped = (clamped / maximumWindowHeightRatioStep).rounded()
            * maximumWindowHeightRatioStep
        return min(max(stepped, minimumWindowHeightRatio), maximumWindowHeightRatio)
    }

    static func maximumPanelHeight(screenHeight: CGFloat, ratio: Double) -> CGFloat {
        let normalizedRatio = normalizedMaximumWindowHeightRatio(ratio)
        return max(smallestMaximumPanelHeight, screenHeight * normalizedRatio)
    }
}

enum PanelVisibilityPolicy {
    static func shouldHide(
        isKeyWindow: Bool,
        isPinned: Bool,
        hasAttachedSheet: Bool,
        hasAnotherApplicationWindow: Bool = false
    ) -> Bool {
        !isKeyWindow && !isPinned && !hasAttachedSheet && !hasAnotherApplicationWindow
    }
}

/// 翻译浮窗使用紧凑的默认宽度，并记住手动调整后的尺寸。
enum TranslationPanelSize {
    static let defaultWidth: CGFloat = 400
    /// 最窄时语言栏仍能放下“简体中文 · 自动”，卡片标题行仍能放下服务名与三个操作按钮。
    static let minimumWidth: CGFloat = 360
}

/// 浮窗弹出位置：记住上次的位置，或每次出现在鼠标旁边。
enum PanelPlacementMode: String, CaseIterable, Identifiable {
    case remember
    case followMouse

    static let storageKey = "panelPlacement.v1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remember: return L10n.text("rememberLastPosition")
        case .followMouse: return L10n.text("followPointer")
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> PanelPlacementMode {
        defaults.string(forKey: storageKey).flatMap(PanelPlacementMode.init(rawValue:)) ?? .remember
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}
