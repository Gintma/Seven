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
    /// In follow-cursor mode, expand downward and to the right from the pointer, clamping inward if it exceeds the visible screen.
    /// Keep `margin` on the left, right, and bottom, with none at the top (`visibleFrame` already excludes the menu bar).
    /// When a selection rect exists, only search around the selection for a minimum-overlap placement if the default position would occlude it.
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

    /// Restores the previous position: keeps the left and top edges fixed and adjusts only height to fit content.
    /// Places the panel on the screen with the largest overlap with the previous frame, falling back to `fallback` if that display was disconnected.
    static func rememberedFrame(
        _ lastFrame: NSRect,
        height: CGFloat,
        screens visibleFrames: [NSRect],
        fallback: NSRect
    ) -> NSRect {
        return frameKeepingTop(lastFrame, height: height, within: screen(mostOverlapping: lastFrame, in: visibleFrames) ?? fallback)
    }

    /// Returns the screen with the largest intersection area with `frame`, or nil if none overlap.
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

    /// Rounds only the origin while keeping width and height unchanged. `NSRect.integral` rounds outward,
    /// which would grow the width by 1 on every popup when cursor coordinates are fractional.
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
    /// Panel height always fits its content (the user can only resize horizontally); this only guards against extremes;
    /// the previous value of 300 left excessive empty space at the bottom when only 0-1 cards were shown.
    static let minimumPanelHeight: CGFloat = 120
    /// Lower bound for the maximum panel height so the cap does not become too small on compact displays.
    static let smallestMaximumPanelHeight: CGFloat = 300
    /// Titlebar height under the compact toolbar style (see toolbarStyle in App.swift).
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

/// Uses a compact default width for the translation panel and remembers manually resized dimensions.
enum TranslationPanelSize {
    static let defaultWidth: CGFloat = 400
    static let horizontalContentInset = Design.Space.l
    static let defaultContentWidth = defaultWidth - 2 * horizontalContentInset
    /// At minimum width, the language bar still fits the auto-detected Chinese label and each card header fits the service name plus three action buttons.
    static let minimumWidth: CGFloat = 360
}

/// Panel popup placement: remember the last position or appear next to the cursor each time.
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
