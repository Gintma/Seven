import AppKit
import ApplicationServices
import Carbon
import Foundation

enum SelectionReadError: LocalizableIssue, Equatable {
    case accessibilityPermission
    case noSelection
    case copyTimedOut

    var issue: LocalizedMessage {
        switch self {
        case .accessibilityPermission:
            return .key("sevenNeedsAccessibilityPermissionToReadSelected")
        case .noSelection:
            return .key("couldNotGetTheSelectedTextMake")
        case .copyTimedOut:
            return .key("theOtherAppDidNotProvideIts")
        }
    }
}

struct SelectedText: Equatable, Sendable {
    let text: String
    let appKitBounds: CGRect?

    init(
        text: String,
        appKitBounds: CGRect?
    ) {
        self.text = text
        self.appKitBounds = appKitBounds
    }
}

enum SelectionTextDecoder {
    private static let fileTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL,
        .init("NSFilenamesPboardType"), .init("NSFileContentsPboardType"), .init("NSFilesPromisePboardType"),
        .init("com.apple.pasteboard.promised-file-url"), .init("com.apple.pasteboard.promised-file-content-type")
    ]

    static func containsFilePayload(_ pasteboard: NSPasteboard) -> Bool {
        if let types = pasteboard.types, !fileTypes.isDisjoint(with: types) { return true }
        return pasteboard.string(forType: .URL).flatMap(URL.init(string:))?.isFileURL == true
    }

    static func normalized(_ value: String) -> String? {
        let normalized = value
            .replacingOccurrences(of: "\0", with: "")
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.contains("\u{FFFD}") else { return nil }
        return normalized
    }

    static func substring(_ value: String, utf16Range: CFRange) -> String? {
        guard utf16Range.location >= 0, utf16Range.length > 0 else { return nil }
        let range = NSRange(location: utf16Range.location, length: utf16Range.length)
        let source = value as NSString
        guard NSMaxRange(range) <= source.length else { return nil }
        return normalized(source.substring(with: range))
    }

    static func text(from pasteboard: NSPasteboard) -> String? {
        let values = (pasteboard.pasteboardItems ?? []).compactMap(text(from:))
        if !values.isEmpty { return normalized(values.joined(separator: "\n")) }
        return normalized(pasteboard.string(forType: .string) ?? "")
    }

    private static func text(from item: NSPasteboardItem) -> String? {
        if let value = item.string(forType: .string), let normalized = normalized(value) {
            return normalized
        }
        if let data = item.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: data, documentAttributes: nil),
           let normalized = normalized(attributed.string) {
            return normalized
        }
        if let data = item.data(forType: .html),
           let attributed = try? NSAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue
               ],
               documentAttributes: nil
           ),
           let normalized = normalized(attributed.string) {
            return normalized
        }
        return nil
    }
}

enum AccessibilityCoordinateSpace {
    static func appKitRect(fromAccessibility rect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

struct PasteboardSnapshot {
    struct Item {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    let items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        return PasteboardSnapshot(items: items)
    }

    @discardableResult
    func restore(to pasteboard: NSPasteboard, ifUnchangedSince expectedChangeCount: Int) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else { return false }
        pasteboard.clearContents()
        let restored: [NSPasteboardItem] = items.compactMap { snapshot in
            let item = NSPasteboardItem()
            var wroteValue = false
            for (type, data) in snapshot.values {
                wroteValue = item.setData(data, forType: type) || wroteValue
            }
            return wroteValue ? item : nil
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
        return true
    }
}

final class SelectionReader: @unchecked Sendable {
    enum CopyMode {
        case confirmedSelection
        case unknownSelection
    }

    enum CopyMenuState {
        case enabled(AXUIElement)
        case disabled
        case unknown
    }

    private enum AccessibilitySelection {
        case none
        case unreadableText
        case unknown
        case text(SelectedText)
    }

    private static let textInputRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
    private static let textSelectionRoles = textInputRoles + [kAXStaticTextRole, "AXWebArea"]
    private static let objectSelectionRoles: Set<String> = [
        "AXIcon", kAXImageRole, kAXRowRole, kAXOutlineRole, kAXBrowserRole, kAXListRole, kAXTableRole,
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXMenuRole, kAXMenuItemRole
    ]

    private let readAttribute: (AXUIElement, String) -> CFTypeRef?
    private let readParameterizedAttribute: (AXUIElement, String, CFTypeRef) -> CFTypeRef?
    private let selectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    private let stringForTextMarkerRangeAttribute = "AXStringForTextMarkerRange"
    private let lengthForTextMarkerRangeAttribute = "AXLengthForTextMarkerRange"
    private let boundsForTextMarkerRangeAttribute = "AXBoundsForTextMarkerRange"

    init(
        parameterizedAttribute: @escaping (AXUIElement, String, CFTypeRef) -> CFTypeRef? = SelectionReader.systemParameterizedAttribute,
        attribute: @escaping (AXUIElement, String) -> CFTypeRef? = SelectionReader.systemAttribute
    ) {
        self.readAttribute = attribute
        self.readParameterizedAttribute = parameterizedAttribute
    }

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    func readSelection(applicationPID: pid_t? = nil) async throws -> SelectedText {
        guard AXIsProcessTrusted() else {
            throw SelectionReadError.accessibilityPermission
        }
        guard let targetPID = applicationPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            throw SelectionReadError.noSelection
        }
        return try await readSelection(
            focused: focusedElement(applicationPID: targetPID),
            applicationPID: targetPID,
            copyMenuState: { self.copyMenuState(application: AXUIElementCreateApplication(targetPID)) },
            copyFallback: { mode, menu in
                try await self.readUsingCopyFallback(applicationPID: targetPID, mode: mode, menu: menu)
            }
        )
    }

    func readSelection(
        focused: AXUIElement?, applicationPID: pid_t?,
        copyMenuState: () -> CopyMenuState = { .unknown },
        copyFallback: (CopyMode, CopyMenuState) async throws -> String
    ) async throws -> SelectedText {
        if let focused, let applicationPID {
            var owner: pid_t = 0
            guard AXUIElementGetPid(focused, &owner) == .success, owner == applicationPID else {
                throw SelectionReadError.noSelection
            }
        }

        let mode: CopyMode
        switch focused.map(accessibilitySelection(startingAt:)) ?? .unknown {
        case .none:
            throw SelectionReadError.noSelection
        case .unreadableText:
            mode = .confirmedSelection
        case .unknown:
            mode = .unknownSelection
        case .text(let selection):
            return selection
        }
        try Task.checkCancellation()
        let menu = copyMenuState()
        if mode == .unknownSelection, case .disabled = menu { throw SelectionReadError.noSelection }
        return SelectedText(text: try await copyFallback(mode, menu), appKitBounds: nil)
    }

    private func hasReportedTextRange(in element: AXUIElement, primary: CFRange?) -> Bool {
        if let primary, primary.length > 0 { return true }
        let ranges = attribute(kAXSelectedTextRangesAttribute, from: element) as? [AnyObject]
        return ranges?.contains { (textRange(from: $0)?.length ?? 0) > 0 } == true
    }

    private func textRange(from value: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0, range.location != NSNotFound, range.length >= 0 else { return nil }
        return range
    }

    private func markerLength(in element: AXUIElement, range: CFTypeRef) -> Int? {
        guard CFGetTypeID(range) == AXTextMarkerRangeGetTypeID(),
              let value = readParameterizedAttribute(element, lengthForTextMarkerRangeAttribute, range) as? NSNumber,
              value.intValue >= 0 else { return nil }
        return value.intValue
    }

    private func accessibilitySelection(startingAt focused: AXUIElement) -> AccessibilitySelection {
        var element = focused
        var hasTextRange = false
        var hasCollapsedMarker = false
        // 网页可能把选区报告在焦点的文档祖先上。窗口、应用和对象选择控件是查找边界。
        for depth in 0...8 {
            let role = attribute(kAXRoleAttribute, from: element) as? String ?? ""
            if role == kAXWindowRole || role == kAXApplicationRole { break }
            if Self.objectSelectionRoles.contains(role) {
                if depth == 0 { return .none }
                break
            }

            let rangeValue = attribute(kAXSelectedTextRangeAttribute, from: element)
            let range = rangeValue.flatMap(textRange(from:))
            let marker = attribute(selectedTextMarkerRangeAttribute, from: element)
            let length = marker.flatMap { markerLength(in: element, range: $0) }
            let reportsText = hasReportedTextRange(in: element, primary: range) || (length ?? 0) > 0
            let isCaret = Self.textInputRoles.contains(role) && range?.length == 0 && marker == nil
            if depth == 0, !reportsText, isCaret || length == 0 { return .none }

            if (Self.textSelectionRoles.contains(role) || reportsText || marker != nil),
               (length != 0 || reportsText),
               let text = selectedText(from: element, rangeValue: rangeValue, markerRangeValue: marker) {
                return .text(SelectedText(
                    text: text,
                    appKitBounds: selectionBounds(
                        from: element,
                        rangeValue: range?.length == 0 ? nil : rangeValue,
                        markerRangeValue: length == 0 ? nil : marker
                    )
                ))
            }
            hasTextRange = hasTextRange || reportsText
            hasCollapsedMarker = hasCollapsedMarker || length == 0
            guard let parent = attribute(kAXParentAttribute, from: element),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = unsafeBitCast(parent, to: AXUIElement.self)
        }
        if hasTextRange { return .unreadableText }
        return hasCollapsedMarker ? .none : .unknown
    }

    private func focusedElement(applicationPID: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(applicationPID)
        if let focused = attribute(kAXFocusedUIElementAttribute, from: application),
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            return unsafeBitCast(focused, to: AXUIElement.self)
        }

        let system = AXUIElementCreateSystemWide()
        guard let focused = attribute(kAXFocusedUIElementAttribute, from: system),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(focused, to: AXUIElement.self)
    }

    private func selectedText(
        from element: AXUIElement,
        rangeValue: CFTypeRef?,
        markerRangeValue: CFTypeRef?
    ) -> String? {
        if let value = attribute(kAXSelectedTextAttribute, from: element),
           let text = string(from: value),
           let normalized = SelectionTextDecoder.normalized(text) {
            return normalized
        }

        if let rangeValue {
            if let selectedValue = readParameterizedAttribute(element, kAXStringForRangeParameterizedAttribute, rangeValue),
               let text = string(from: selectedValue),
               let normalized = SelectionTextDecoder.normalized(text) {
                return normalized
            }

            if let range = textRange(from: rangeValue),
               let value = attribute(kAXValueAttribute, from: element),
               let text = string(from: value),
               let selected = SelectionTextDecoder.substring(text, utf16Range: range) {
                return selected
            }
        }

        if let markerRangeValue {
            if let selectedValue = readParameterizedAttribute(element, stringForTextMarkerRangeAttribute, markerRangeValue),
               let text = string(from: selectedValue),
               let normalized = SelectionTextDecoder.normalized(text) {
                return normalized
            }
        }
        return nil
    }

    private func selectionBounds(
        from element: AXUIElement,
        rangeValue: CFTypeRef?,
        markerRangeValue: CFTypeRef?
    ) -> CGRect? {
        if let rangeValue,
           let bounds = parameterizedBounds(
               from: element,
               attribute: kAXBoundsForRangeParameterizedAttribute,
               parameter: rangeValue
           ) {
            return appKitBounds(bounds)
        }
        if let markerRangeValue,
           let bounds = parameterizedBounds(
               from: element,
               attribute: boundsForTextMarkerRangeAttribute,
               parameter: markerRangeValue
           ) {
            return appKitBounds(bounds)
        }
        return nil
    }

    private func parameterizedBounds(
        from element: AXUIElement,
        attribute name: String,
        parameter: CFTypeRef
    ) -> CGRect? {
        guard let boundsValue = readParameterizedAttribute(element, name, parameter),
              CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        let axBounds = unsafeBitCast(boundsValue, to: AXValue.self)
        guard AXValueGetType(axBounds) == .cgRect else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(axBounds, .cgRect, &bounds), bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    private func appKitBounds(_ bounds: CGRect) -> CGRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
        return AccessibilityCoordinateSpace.appKitRect(
            fromAccessibility: bounds,
            primaryScreenMaxY: primaryMaxY
        )
    }

    private func attribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
        readAttribute(element, name)
    }

    private static func systemAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func systemParameterizedAttribute(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success else { return nil }
        return value
    }

    private func string(from value: CFTypeRef) -> String? {
        if let text = value as? String { return text }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    private func readUsingCopyFallback(applicationPID: pid_t, mode: CopyMode, menu: CopyMenuState) async throws -> String {
        try await readUsingCopyFallback(
            pasteboard: .general,
            mode: mode,
            targetIsFrontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier == applicationPID },
            invokeMenuCopy: {
                guard case .enabled(let item) = menu else { return false }
                AXUIElementSetMessagingTimeout(item, 0.05)
                let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
                // 超时的动作可能已派发。先等剪贴板结果，避免立即重复复制。
                return result == .success || result == .cannotComplete
            },
            sendCopyShortcut: { await self.postShortcut(keyCode: UInt16(kVK_ANSI_C), to: applicationPID) }
        )
    }

    func readUsingCopyFallback(
        pasteboard: NSPasteboard,
        mode: CopyMode = .confirmedSelection,
        targetIsFrontmost: () -> Bool,
        invokeMenuCopy: () -> Bool,
        sendCopyShortcut: () async -> Bool
    ) async throws -> String {
        try Task.checkCancellation()
        guard targetIsFrontmost() else { throw SelectionReadError.noSelection }
        let originalChangeCount = pasteboard.changeCount
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        try Task.checkCancellation()
        guard targetIsFrontmost(), pasteboard.changeCount == originalChangeCount else {
            throw SelectionReadError.noSelection
        }
        let clearedChangeCount = pasteboard.clearContents()
        var restoreChangeCount = clearedChangeCount
        defer { _ = snapshot.restore(to: pasteboard, ifUnchangedSince: restoreChangeCount) }
        let invokedCopy = invokeMenuCopy() ? true : await sendCopyShortcut()
        guard invokedCopy else { throw SelectionReadError.copyTimedOut }

        let started = ContinuousClock.now
        let allowsRetry = mode == .confirmedSelection
        let deadline = started.advanced(by: allowsRetry ? .milliseconds(2_400) : .milliseconds(500))
        let retryAt = started.advanced(by: .milliseconds(420))
        var sawPasteboardChange = false
        var retriedCopy = false
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(30))
            guard targetIsFrontmost() else { throw SelectionReadError.noSelection }
            let changeCount = pasteboard.changeCount
            if changeCount != clearedChangeCount {
                sawPasteboardChange = true
                restoreChangeCount = changeCount
                let containsFile = SelectionTextDecoder.containsFilePayload(pasteboard)
                let text = containsFile ? nil : SelectionTextDecoder.text(from: pasteboard)
                guard pasteboard.changeCount == changeCount else { continue }
                if containsFile { throw SelectionReadError.noSelection }
                if let text {
                    try Task.checkCancellation()
                    guard targetIsFrontmost() else { throw SelectionReadError.noSelection }
                    return text
                }
            }
            if allowsRetry, !retriedCopy, ContinuousClock.now >= retryAt {
                retriedCopy = true
                if !invokeMenuCopy() {
                    _ = await sendCopyShortcut()
                }
            }
        }

        if sawPasteboardChange { throw SelectionReadError.noSelection }
        throw SelectionReadError.copyTimedOut
    }

    func copyMenuState(application: AXUIElement, timeout: TimeInterval = 0.075) -> CopyMenuState {
        let clock = ProcessInfo.processInfo
        let deadline = clock.systemUptime + timeout
        func query(_ name: String, from element: AXUIElement) -> CFTypeRef? {
            let remaining = deadline - clock.systemUptime
            guard remaining > 0,
                  AXUIElementSetMessagingTimeout(element, Float(min(remaining, 0.02))) == .success else { return nil }
            return attribute(name, from: element)
        }
        guard let menuBarValue = query(kAXMenuBarAttribute, from: application),
              CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else { return .unknown }

        let menuBar = unsafeBitCast(menuBarValue, to: AXUIElement.self)
        var queue = [menuBar]
        var seen = Set<AXUIElement>()
        var index = 0
        var match: CopyMenuState?
        while index < queue.count {
            guard clock.systemUptime < deadline, seen.count < 500 else { return .unknown }
            let element = queue[index]
            index += 1
            guard seen.insert(element).inserted else { continue }

            if query(kAXRoleAttribute, from: element) as? String == kAXMenuItemRole,
               let command = query(kAXMenuItemCmdCharAttribute, from: element) as? String,
               command.caseInsensitiveCompare("c") == .orderedSame {
                guard let modifiers = query(kAXMenuItemCmdModifiersAttribute, from: element) as? NSNumber else { return .unknown }
                if modifiers.uint32Value == 0 {
                    guard match == nil, let enabled = query(kAXEnabledAttribute, from: element),
                          CFGetTypeID(enabled) == CFBooleanGetTypeID(),
                          let value = enabled as? NSNumber else { return .unknown }
                    match = value.boolValue ? .enabled(element) : .disabled
                }
            }

            if let children = query(kAXChildrenAttribute, from: element) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        guard clock.systemUptime < deadline else { return .unknown }
        return match ?? .unknown
    }

    /// 标记 Seven 自己模拟的按键，供快捷键录制窗口识别并忽略。
    static let syntheticEventMarker: Int64 = 0x5356_5359  // "SVSY"

    static func isSynthetic(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker
    }

    private func postShortcut(keyCode: UInt16, to applicationPID: pid_t) async -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        down.postToPid(applicationPID)
        try? await Task.sleep(for: .milliseconds(14))
        up.postToPid(applicationPID)
        return true
    }
}
