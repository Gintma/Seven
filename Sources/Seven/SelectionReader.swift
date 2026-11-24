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
    private let readAttribute: (AXUIElement, String) -> CFTypeRef?
    private let selectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    private let stringForTextMarkerRangeAttribute = "AXStringForTextMarkerRange"
    private let boundsForTextMarkerRangeAttribute = "AXBoundsForTextMarkerRange"

    init(attribute: @escaping (AXUIElement, String) -> CFTypeRef? = SelectionReader.systemAttribute) {
        self.readAttribute = attribute
    }

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    func readSelection(applicationPID: pid_t? = nil) async throws -> SelectedText {
        guard AXIsProcessTrusted() else {
            throw SelectionReadError.accessibilityPermission
        }
        let targetPID = applicationPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        return try await readSelection(
            focused: focusedElement(applicationPID: targetPID),
            applicationPID: targetPID,
            copyFallback: { try await self.readUsingCopyFallback(applicationPID: targetPID) }
        )
    }

    func readSelection(
        focused: AXUIElement?, applicationPID: pid_t?,
        copyFallback: () async throws -> String
    ) async throws -> SelectedText {
        if let focused {
            if hasEmptyTextSelection(in: focused, applicationPID: applicationPID) {
                throw SelectionReadError.noSelection
            }
            if let direct = accessibilitySelection(startingAt: focused, applicationPID: applicationPID) {
                return direct
            }
        }
        return SelectedText(text: try await copyFallback(), appKitBounds: nil)
    }

    private func hasEmptyTextSelection(in element: AXUIElement, applicationPID: pid_t?) -> Bool {
        if let applicationPID {
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == applicationPID else { return false }
        }
        guard let role = attribute(kAXRoleAttribute, from: element) as? String,
              role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole,
              let rangeValue = attribute(kAXSelectedTextRangeAttribute, from: element),
              isCaretRange(rangeValue),
              attribute(selectedTextMarkerRangeAttribute, from: element) == nil else { return false }

        if let selections = attribute(kAXSelectedTextRangesAttribute, from: element) {
            guard let ranges = selections as? [AnyObject], ranges.allSatisfy(isCaretRange) else { return false }
        }
        guard let selectedText = attribute(kAXSelectedTextAttribute, from: element) else { return true }
        return string(from: selectedText)?.isEmpty == true
    }

    private func isCaretRange(_ value: CFTypeRef) -> Bool {
        guard let range = textRange(from: value) else { return false }
        return range.location >= 0 && range.location != NSNotFound && range.length == 0
    }

    private func textRange(from value: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private func accessibilitySelection(startingAt focused: AXUIElement, applicationPID: pid_t?) -> SelectedText? {
        for element in selectionCandidates(startingAt: focused, applicationPID: applicationPID) {
            let rangeValue = attribute(kAXSelectedTextRangeAttribute, from: element)
            let markerRangeValue = attribute(selectedTextMarkerRangeAttribute, from: element)
            if let text = selectedText(
                from: element,
                rangeValue: rangeValue,
                markerRangeValue: markerRangeValue
            ) {
                return SelectedText(
                    text: text,
                    appKitBounds: selectionBounds(
                        from: element,
                        rangeValue: rangeValue,
                        markerRangeValue: markerRangeValue
                    )
                )
            }
        }
        return nil
    }

    private func selectionCandidates(
        startingAt focused: AXUIElement,
        applicationPID: pid_t?
    ) -> [AXUIElement] {
        var candidates: [AXUIElement] = []
        var seen = Set<CFHashCode>()

        func append(_ element: AXUIElement) {
            guard seen.insert(CFHash(element)).inserted else { return }
            candidates.append(element)
        }

        append(focused)
        var current = focused
        for _ in 0..<8 {
            guard let parentValue = attribute(kAXParentAttribute, from: current),
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { break }
            let parent = unsafeBitCast(parentValue, to: AXUIElement.self)
            append(parent)
            current = parent
        }

        guard let applicationPID else { return candidates }
        let application = AXUIElementCreateApplication(applicationPID)
        var roots: [AXUIElement] = []
        if let windowValue = attribute(kAXFocusedWindowAttribute, from: application),
           CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            roots.append(unsafeBitCast(windowValue, to: AXUIElement.self))
        }
        roots.append(application)

        var queue = roots
        var index = 0
        while index < queue.count, candidates.count < 1_200 {
            let element = queue[index]
            index += 1
            append(element)
            guard let childrenValue = attribute(kAXChildrenAttribute, from: element),
                  let children = childrenValue as? [AXUIElement] else { continue }
            for child in children where !seen.contains(CFHash(child)) {
                queue.append(child)
            }
        }
        return candidates
    }

    private func focusedElement(applicationPID: pid_t?) -> AXUIElement? {
        if let applicationPID {
            let application = AXUIElementCreateApplication(applicationPID)
            if let focused = attribute(kAXFocusedUIElementAttribute, from: application) {
                return unsafeBitCast(focused, to: AXUIElement.self)
            }
        }

        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedValue
        ) == .success, let focusedValue else { return nil }
        return unsafeBitCast(focusedValue, to: AXUIElement.self)
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
            var selectedValue: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &selectedValue
            ) == .success,
               let selectedValue,
               let text = string(from: selectedValue),
               let normalized = SelectionTextDecoder.normalized(text) {
                return normalized
            }

            if let range = textRange(from: rangeValue),
               let value = attribute(kAXValueAttribute, from: element),
               let text = string(from: value) {
                return SelectionTextDecoder.substring(text, utf16Range: range)
            }
        }

        if let markerRangeValue {
            var selectedValue: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                stringForTextMarkerRangeAttribute as CFString,
                markerRangeValue,
                &selectedValue
            ) == .success,
               let selectedValue,
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
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            name as CFString,
            parameter,
            &boundsValue
        ) == .success,
              let boundsValue,
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

    private func string(from value: CFTypeRef) -> String? {
        if let text = value as? String { return text }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    private func readUsingCopyFallback(applicationPID: pid_t?) async throws -> String {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        let clearedChangeCount = pasteboard.changeCount
        var restoreChangeCount = clearedChangeCount
        defer { _ = snapshot.restore(to: pasteboard, ifUnchangedSince: restoreChangeCount) }
        let invokedCopyMenu = applicationPID.map { performMenuItem(applicationPID: $0, command: "c") } ?? false
        let invokedCopy = invokedCopyMenu ? true : await postShortcut(keyCode: UInt16(kVK_ANSI_C), to: applicationPID)
        guard invokedCopy else {
            throw SelectionReadError.copyTimedOut
        }

        let deadline = ContinuousClock.now.advanced(by: .milliseconds(2_400))
        let retryAt = ContinuousClock.now.advanced(by: .milliseconds(420))
        var sawPasteboardChange = false
        var retriedCopy = false
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(30))
            if let applicationPID,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != applicationPID {
                throw SelectionReadError.noSelection
            }
            if pasteboard.changeCount != clearedChangeCount {
                sawPasteboardChange = true
                restoreChangeCount = pasteboard.changeCount
                if let value = SelectionTextDecoder.text(from: pasteboard) { return value }
            }
            if !retriedCopy, ContinuousClock.now >= retryAt {
                retriedCopy = true
                if !(applicationPID.map { performMenuItem(applicationPID: $0, command: "c") } ?? false) {
                    _ = await postShortcut(keyCode: UInt16(kVK_ANSI_C), to: applicationPID)
                }
            }
        }

        if sawPasteboardChange { throw SelectionReadError.noSelection }
        throw SelectionReadError.copyTimedOut
    }

    private func performMenuItem(applicationPID: pid_t, command: String) -> Bool {
        let application = AXUIElementCreateApplication(applicationPID)
        guard let menuBarValue = attribute(kAXMenuBarAttribute, from: application),
              CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else { return false }
        let menuBar = unsafeBitCast(menuBarValue, to: AXUIElement.self)
        if let item = menuItem(in: menuBar, command: command) {
            return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        }

        for menu in children(of: menuBar).prefix(16) {
            guard AXUIElementPerformAction(menu, kAXPressAction as CFString) == .success else { continue }
            if let item = menuItem(in: menu, command: command),
               AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                return true
            }
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        }
        return false
    }

    private func menuItem(in root: AXUIElement, command expectedCommand: String) -> AXUIElement? {
        var queue = [root]
        var seen = Set<CFHashCode>()
        var index = 0

        while index < queue.count, seen.count < 500 {
            let element = queue[index]
            index += 1
            guard seen.insert(CFHash(element)).inserted else { continue }
            let role = attribute(kAXRoleAttribute, from: element) as? String
            if role == kAXMenuItemRole,
               let command = attribute(kAXMenuItemCmdCharAttribute, from: element) as? String,
               command.caseInsensitiveCompare(expectedCommand) == .orderedSame {
                let modifiers = (attribute(kAXMenuItemCmdModifiersAttribute, from: element) as? NSNumber)?.uint32Value ?? 0
                let enabled = (attribute(kAXEnabledAttribute, from: element) as? NSNumber)?.boolValue ?? true
                if modifiers == 0, enabled { return element }
            }
            queue.append(contentsOf: children(of: element))
        }
        return nil
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let childrenValue = attribute(kAXChildrenAttribute, from: element),
              let children = childrenValue as? [AXUIElement] else { return [] }
        return children
    }

    /// 标记 Seven 自己模拟的按键，供快捷键录制窗口识别并忽略。
    static let syntheticEventMarker: Int64 = 0x5356_5359  // "SVSY"

    static func isSynthetic(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker
    }

    private func postShortcut(keyCode: UInt16, to applicationPID: pid_t?) async -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        if let applicationPID { down.postToPid(applicationPID) }
        else { down.post(tap: .cghidEventTap) }
        try? await Task.sleep(for: .milliseconds(14))
        if let applicationPID { up.postToPid(applicationPID) }
        else { up.post(tap: .cghidEventTap) }
        return true
    }
}
