import AppKit
import ApplicationServices

struct InputReplacementAXReader {
    private let element: AXUIElement
    private let attribute: (String) -> CFTypeRef?
    private let parameterized: (String, CFTypeRef) -> CFTypeRef?
    private let trace: (String) -> Void

    init(element: AXUIElement, attribute: @escaping (String) -> CFTypeRef?,
         parameterized: @escaping (String, CFTypeRef) -> CFTypeRef?, trace: @escaping (String) -> Void = { _ in }) {
        self.element = element
        self.attribute = attribute
        self.parameterized = parameterized
        self.trace = trace
    }

    init(element: AXUIElement) {
        self.init(element: element, attribute: { name in
            Self.attribute(name, of: element)
        }, parameterized: { name, parameter in
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &result) == .success else {
                return nil
            }
            return result
        }, trace: InputReplacementTarget.trace)
    }

    func read(usingTextMarkers: Bool? = nil) throws -> InputReplacementSnapshot {
        if usingTextMarkers == true { return try readTextMarkerSnapshot() }
        do {
            return try readRangeSnapshot()
        } catch InputReplacementError.unreadable where usingTextMarkers == nil {
            trace("range.unreadable")
            return try readTextMarkerSnapshot()
        }
    }

    private func readRangeSnapshot() throws -> InputReplacementSnapshot {
        let count = (attribute(kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
        // 空框可能不提供选区属性；先读取实际字符数，不能先因选区缺失报错。
        if count == 0 { throw InputReplacementError.empty }
        let raw = attribute(kAXValueAttribute) as? String
        let placeholder = attribute(kAXPlaceholderValueAttribute) as? String
        let requestedLength = count ?? raw.map { ($0 as NSString).length }
        let documentText = requestedLength.flatMap { length in
            length > 0 ? string(in: NSRange(location: 0, length: length)) : nil
        }
        let text: String
        do {
            text = try InputReplacementContent.resolve(value: raw, characterCount: count,
                                                       placeholder: placeholder, documentText: documentText)
        } catch InputReplacementError.unreadable {
            trace("range.document_unavailable")
            throw InputReplacementError.unreadable
        }
        guard let selection = attribute(kAXSelectedTextRangeAttribute), CFGetTypeID(selection) == AXValueGetTypeID() else {
            trace("range.selection_missing")
            throw InputReplacementError.unreadable
        }
        let axRange = unsafeBitCast(selection, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axRange) == .cfRange, AXValueGetValue(axRange, .cfRange, &range),
              range.location >= 0, range.length >= 0 else {
            trace("range.selection_invalid")
            throw InputReplacementError.unreadable
        }
        let nativeRange = NSRange(location: range.location, length: range.length)
        let selectedText = range.length > 0 ? (string(in: nativeRange) ?? attribute(kAXSelectedTextAttribute) as? String) : nil
        let snapshot = try InputReplacementSnapshot(value: raw ?? text, range: nativeRange,
                                                    nativeCharacterCount: count, selectedText: selectedText)
        try snapshot.validateContent()
        return snapshot
    }

    func string(in selection: NSRange) -> String? {
        var range = CFRange(location: selection.location, length: selection.length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        return parameterized(kAXStringForRangeParameterizedAttribute, parameter) as? String
    }

    func textMarkerDocument() -> String? {
        guard let range = textMarkerRange(parameterized("AXTextMarkerRangeForUIElement", element)) else { return nil }
        return text(in: range)
    }

    private func readTextMarkerSnapshot() throws -> InputReplacementSnapshot {
        // Chromium 的富文本编辑器可能只提供文本标记。用控件自身的范围，不用页面的首尾标记。
        guard let field = textMarkerRange(parameterized("AXTextMarkerRangeForUIElement", element)),
              let document = text(in: field) else {
            trace("marker.document_unavailable")
            throw InputReplacementError.unreadable
        }
        _ = try InputReplacementContent.resolve(value: document, characterCount: nil,
            placeholder: attribute(kAXPlaceholderValueAttribute) as? String, documentText: document)
        guard let selection = textMarkerRange(attribute("AXSelectedTextMarkerRange")) else {
            trace("marker.selection_missing")
            throw InputReplacementError.unreadable
        }
        let anchor = AXTextMarkerRangeCopyStartMarker(selection)
        let focus = AXTextMarkerRangeCopyEndMarker(selection)
        guard belongsToField(anchor), belongsToField(focus) else {
            trace("marker.endpoint_outside")
            throw InputReplacementError.unreadable
        }
        guard let ordered = textMarkerRange(parameterized("AXTextMarkerRangeForUnorderedTextMarkers", [anchor, focus] as CFArray)),
              let selected = text(in: ordered) else {
            trace("marker.selection_unavailable")
            throw InputReplacementError.unreadable
        }

        let prefixRange = AXTextMarkerRangeCreate(nil, AXTextMarkerRangeCopyStartMarker(field), AXTextMarkerRangeCopyStartMarker(ordered))
        let suffixRange = AXTextMarkerRangeCreate(nil, AXTextMarkerRangeCopyEndMarker(ordered), AXTextMarkerRangeCopyEndMarker(field))
        guard let prefix = text(in: prefixRange), let suffix = text(in: suffixRange),
              (prefix + selected + suffix).utf16.elementsEqual(document.utf16) else {
            trace("marker.partition_mismatch")
            throw InputReplacementError.unreadable
        }
        return try InputReplacementSnapshot(value: document,
            range: NSRange(location: prefix.utf16.count, length: selected.utf16.count), usesTextMarkers: true)
    }

    private func belongsToField(_ marker: AXTextMarker) -> Bool {
        var node = parameterized("AXUIElementForTextMarker", marker)
        for _ in 0..<16 {
            guard let current = node, CFGetTypeID(current) == AXUIElementGetTypeID() else { return false }
            if CFEqual(current, element) { return true }
            let parent = unsafeBitCast(current, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(parent, 0.05)
            node = Self.attribute(kAXParentAttribute, of: parent)
        }
        return false
    }

    private func text(in range: AXTextMarkerRange) -> String? {
        parameterized("AXStringForTextMarkerRange", range) as? String
    }

    private func textMarkerRange(_ value: CFTypeRef?) -> AXTextMarkerRange? {
        guard let value, CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXTextMarkerRange.self)
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
}
