import AppKit
import ApplicationServices
import Carbon

/// Stores AX display text and native selection coordinates separately; link/attachment coordinates cannot be applied directly to expanded text.
struct InputReplacementSnapshot: Equatable {
    let value: String
    let range: NSRange
    let usesTextMarkers: Bool
    private let selectedText: String?

    init(value: String, range: NSRange, nativeCharacterCount: Int? = nil, selectedText: String? = nil,
         usesTextMarkers: Bool = false) throws {
        let valueLength = (value as NSString).length
        let coordinateLength = nativeCharacterCount ?? valueLength
        guard coordinateLength >= 0, range.location >= 0, range.length >= 0, range.location != NSNotFound,
              range.location <= coordinateLength, range.length <= coordinateLength - range.location else {
            throw InputReplacementError.unreadable
        }
        if range.length > 0, NSMaxRange(range) > valueLength, selectedText == nil {
            throw InputReplacementError.unreadable
        }
        self.value = value
        self.range = range
        self.selectedText = selectedText
        self.usesTextMarkers = usesTextMarkers
    }

    var replacesWholeInput: Bool { range.length == 0 }
    var replacementRange: NSRange { replacesWholeInput ? NSRange(location: 0, length: (value as NSString).length) : range }
    var text: String {
        if !replacesWholeInput, let selectedText { return selectedText }
        return (value as NSString).substring(with: replacementRange)
    }
    func replacing(with text: String) -> String? {
        guard NSMaxRange(replacementRange) <= (value as NSString).length else { return nil }
        if !replacesWholeInput, let selectedText,
           (value as NSString).substring(with: replacementRange) != selectedText { return nil }
        return (value as NSString).replacingCharacters(in: replacementRange, with: text)
    }

    /// Some editors expose placeholder text as AXValue; do not treat it as source text when actual character count is zero.
    func validateContent(characterCount: Int? = nil, placeholder: String? = nil) throws {
        guard characterCount != 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InputReplacementError.empty
        }
        if let placeholder, !placeholder.isEmpty, value == placeholder, characterCount == nil, text == placeholder {
            throw InputReplacementError.empty
        }
        guard text.count <= 20_000 else { throw InputReplacementError.tooLong }
    }

}

enum InputReplacementError: Error, Equatable, LocalizableIssue {
    case unreadable, focusUnavailable, readOnly, focusChanged, controlChanged, contentChanged, selectionChanged, selectionUnavailable, empty, tooLong, failed, noService, timedOut
    var issue: LocalizedMessage {
        switch self {
        case .unreadable, .focusUnavailable: return .key("couldNotReliablyReadTheCurrentField")
        case .readOnly: return .key("useThisInAnEditableTextField")
        case .focusChanged: return .key("theFrontmostAppChangedReplacementStopped")
        case .controlChanged: return .key("theCurrentTextFieldChangedReplacementStopped")
        case .contentChanged: return .key("theTextInTheFieldChangedReplacement")
        case .selectionChanged: return .key("theSelectionChangedReplacementStopped")
        case .selectionUnavailable: return .key("couldNotVerifyThatTheFullField")
        case .empty: return .verbatim("没有可翻译的文字。")
        case .tooLong: return .key("youCanTranslateUpTo20000")
        case .failed: return .key("couldNotVerifyTheReplacementCheckThe")
        case .noService: return .key("enableAndExpandAServiceInTranslation")
        case .timedOut: return .key("translationTimedOutTryAgainLater")
        }
    }
}

/// After native Select All, wait for a real selection to appear rather than treating a stale AX read as a user edit.
@MainActor
enum InputReplacementSelection {
    static func validate(_ current: InputReplacementSnapshot, against original: InputReplacementSnapshot,
                         range: NSRange? = nil) throws {
        guard current.value.utf16.elementsEqual(original.value.utf16) else { throw InputReplacementError.contentChanged }
        guard current.range == (range ?? original.range) else { throw InputReplacementError.selectionChanged }
    }

    @discardableResult
    static func selectWholeInput(
        original: InputReplacementSnapshot,
        read: () throws -> InputReplacementSnapshot,
        checkTarget: () throws -> Void,
        selectAll: () throws -> Void,
        attempts: Int = 30,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(20)) }
    ) async throws -> InputReplacementSnapshot {
        // Use the whole-field path only when there is definitively no selection; never downgrade a selection read failure to Select All.
        guard original.replacesWholeInput else { throw InputReplacementError.selectionChanged }
        try Task.checkCancellation()
        try checkTarget()
        try validate(read(), against: original)
        try selectAll()
        for _ in 0..<attempts {
            try Task.checkCancellation()
            try checkTarget()
            let current = try read()
            guard current.value.utf16.elementsEqual(original.value.utf16) else { throw InputReplacementError.contentChanged }
            // Native selection coordinates for links/attachments may not match the UTF-16 length of expanded AXValue text.
            // Treat the Command-A result as the new baseline instead of estimating its expected length from another text representation.
            if current.range.length > 0 {
                if original.usesTextMarkers, current.range != original.replacementRange {
                    throw InputReplacementError.selectionUnavailable
                }
                return current
            }
            guard current.range == original.range else { throw InputReplacementError.selectionChanged }
            try await pause()
        }
        let current = try read()
        try validate(current, against: original)
        // Continue copying even if native Select All yields no selection; two empty/whitespace-only reads end silently per product rules.
        return current
    }
}

@MainActor
protocol InputReplacementTargeting {
    var snapshot: InputReplacementSnapshot { get }
    var anchor: NSPoint? { get }
    var translationText: String { get }
    func prepare() async throws
    func replace(with text: String) async throws
}

extension InputReplacementTargeting {
    var anchor: NSPoint? { nil }
    var translationText: String { snapshot.text }
    func prepare() async throws { try snapshot.validateContent() }
}

@MainActor
final class InputReplacementTarget: InputReplacementTargeting {
    let pid: pid_t
    let snapshot: InputReplacementSnapshot
    private let element: AXUIElement
    private let reader: InputReplacementAXReader
    private var preparedSnapshot: InputReplacementSnapshot?
    private var copiedText: String?
    var translationText: String { copiedText ?? snapshot.text }
    var anchor: NSPoint? {
        guard let raw = Self.value(kAXPositionAttribute, of: element), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgPoint, &point), let screen = NSScreen.screens.first else { return nil }
        return NSPoint(x: point.x, y: screen.frame.maxY - point.y + Design.Space.s)
    }

    private init(pid: pid_t, element: AXUIElement, reader: InputReplacementAXReader, snapshot: InputReplacementSnapshot) {
        self.pid = pid; self.element = element; self.snapshot = snapshot
        self.reader = reader
    }

    static func capture(pid: pid_t) throws -> InputReplacementTarget {
        trace("capture.start")
        guard AXIsProcessTrusted() else { throw SelectionReadError.accessibilityPermission }
        let element: AXUIElement
        do {
            element = try focused(pid: pid)
        } catch InputReplacementError.unreadable {
            throw InputReplacementError.focusUnavailable
        }
        let role = value(kAXRoleAttribute, of: element) as? String
        let subrole = value(kAXSubroleAttribute, of: element) as? String
        guard subrole != "AXSecureTextField",
              (value("AXProtectedContent", of: element) as? NSNumber)?.boolValue != true, [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role ?? "") else {
            trace("capture.ineligible_control")
            throw InputReplacementError.readOnly
        }
        var editable = DarwinBoolean(false)
        let canWrite = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &editable) == .success && editable.boolValue
        if !canWrite {
            guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &editable) == .success && editable.boolValue else {
                trace("capture.read_only")
                throw InputReplacementError.readOnly
            }
        }
        let reader = InputReplacementAXReader(element: element)
        let snapshot = try reader.read()
        try snapshot.validateContent()
        trace("capture.ready")
        return InputReplacementTarget(pid: pid, element: element, reader: reader, snapshot: snapshot)
    }

    func validate() throws {
        try validateFocus()
        try InputReplacementSelection.validate(currentSnapshot(), against: preparedSnapshot ?? snapshot)
    }

    private func currentSnapshot() throws -> InputReplacementSnapshot {
        try reader.read(usingTextMarkers: snapshot.usesTextMarkers)
    }

    /// Native copy confirmation runs before any network request; never treat an editor's accessibility title or stale AXValue as user input.
    func prepare() async throws {
        var stage = "prepare"
        do {
            try Task.checkCancellation()
            try validate()
            stage = "select_all"
            if snapshot.replacesWholeInput {
                preparedSnapshot = try await InputReplacementSelection.selectWholeInput(
                    original: snapshot,
                    read: { try self.currentSnapshot() },
                    checkTarget: { try self.validateFocus() },
                    selectAll: { try self.postCommand(keyCode: UInt16(kVK_ANSI_A)) }
                )
            } else {
                preparedSnapshot = snapshot
            }
            try checkPreparingTarget()
            stage = "copy"
            let copied = try await InputReplacementClipboardProbe.verify(
                copy: { try self.postCommand(keyCode: UInt16(kVK_ANSI_C)) },
                checkTarget: { try self.checkPreparingTarget() }
            )
            try Task.checkCancellation()
            try validateFocus()
            try checkPreparingTarget()
            guard let preparedSnapshot, preparedSnapshot.range.length > 0 else { throw InputReplacementError.selectionUnavailable }
            guard copied.count <= 20_000 else { throw InputReplacementError.tooLong }
            copiedText = copied
        } catch {
            recordFailure(error, stage: stage)
            throw error
        }
    }

    private func checkPreparingTarget() throws {
        try validateFocus()
        guard let preparedSnapshot else { throw InputReplacementError.selectionUnavailable }
        try InputReplacementSelection.validate(currentSnapshot(), against: preparedSnapshot)
    }

    func replace(with text: String) async throws {
        var stage = "prewrite"
        do {
            try Task.checkCancellation()
            try validate()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationError.empty }
            guard preparedSnapshot != nil else { throw InputReplacementError.selectionUnavailable }
            try checkPreparingTarget()
            stage = "paste"
            try await paste(text)
            try validateFocus()
            stage = "confirm"
            guard outputMatches(text) else { throw InputReplacementError.failed }
        } catch {
            recordFailure(error, stage: stage)
            throw error
        }
    }

    private func outputMatches(_ text: String) -> Bool {
        guard let preparedSnapshot else { return false }
        if preparedSnapshot.usesTextMarkers {
            return InputReplacementWriteVerification.matches(
                translated: text, before: preparedSnapshot, wholeInput: snapshot.replacesWholeInput,
                insertedText: nil, currentValue: nil, currentDocument: reader.textMarkerDocument()
            )
        }
        let insertion = reader.string(in: NSRange(location: preparedSnapshot.range.location, length: (text as NSString).length))
        let raw = Self.value(kAXValueAttribute, of: element) as? String
        var document: String?
        if let count = (Self.value(kAXNumberOfCharactersAttribute, of: element) as? NSNumber)?.intValue, count > 0 {
            document = reader.string(in: NSRange(location: 0, length: count))
        }
        return InputReplacementWriteVerification.matches(
            translated: text, before: preparedSnapshot, wholeInput: snapshot.replacesWholeInput,
            insertedText: insertion, currentValue: raw, currentDocument: document
        )
    }

    /// Logs only fixed stages, error categories, and character counts to locate interception points during repro; never logs text or links.
    private func recordFailure(_ error: Error, stage: String) {
        let category = (error as? InputReplacementError).map { String(describing: $0) }
            ?? String(reflecting: type(of: error))
        let count = snapshot.value.count
        Task {
            await FileDiagnosticLogger.shared.record(error as? InputReplacementError == .empty ? .info : .warning,
                error as? InputReplacementError == .empty ? "input_replacement_empty" : "input_replacement_rejected", metadata: [
                "error_type": stage + "." + category, "characters": String(count)
            ])
        }
    }

    private func validateFocus() throws {
        guard CFEqual(try Self.focused(pid: pid), element) else { throw InputReplacementError.controlChanged }
    }

    /// Uses native paste in the source app to preserve Undo; never sends Enter and never activates or switches apps.
    private func paste(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        let previous = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        let clearedCount = pasteboard.changeCount
        guard pasteboard.setString(text, forType: .string) else {
            _ = previous.restore(to: pasteboard, ifUnchangedSince: clearedCount)
            throw InputReplacementError.failed
        }
        let lease = pasteboard.changeCount
        defer { _ = previous.restore(to: pasteboard, ifUnchangedSince: lease) }
        try postCommand(keyCode: UInt16(kVK_ANSI_V))
        // Give the source app time to process native paste; restore the clipboard early only once the expected result is observed, up to 1 second.
        // Do not cancel the lease during writeback so the old clipboard is not restored before the source app reads it.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(50))
            if outputMatches(text) { break }
        }
    }

    /// Sends native Command key chords to the verified process for Select All, Copy, and Paste.
    private func postCommand(keyCode: UInt16) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            throw InputReplacementError.failed
        }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: SelectionReader.syntheticEventMarker)
            event.postToPid(pid)
        }
    }

    private static func focused(pid: pid_t) throws -> AXUIElement {
        try focused(pid: pid, frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                    appFocus: applicationFocus, systemFocus: systemWideFocus, report: trace)
    }

    static func focused(
        pid: pid_t,
        frontmostPID: @MainActor () -> pid_t?,
        appFocus: @MainActor (pid_t) -> AXUIElement?,
        systemFocus: @MainActor () -> AXUIElement?,
        report: @MainActor (String) -> Void = { _ in }
    ) throws -> AXUIElement {
        guard frontmostPID() == pid else { throw InputReplacementError.focusChanged }
        if let element = appFocus(pid) {
            AXUIElementSetMessagingTimeout(element, 0.5)
            return element
        }
        // Some apps do not report app-level focus; accept system focus only if it belongs to the same frontmost process.
        let systemElement = systemFocus()
        guard frontmostPID() == pid else { throw InputReplacementError.focusChanged }
        var owner: pid_t = 0
        guard let systemElement, AXUIElementGetPid(systemElement, &owner) == .success, owner == pid else {
            report("focus.system.target_unavailable")
            throw InputReplacementError.unreadable
        }
        report("focus.system.resolved")
        AXUIElementSetMessagingTimeout(systemElement, 0.5)
        return systemElement
    }

    private static func applicationFocus(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        return focusedElement(in: app, scope: "app")
    }

    private static func systemWideFocus() -> AXUIElement? {
        focusedElement(in: AXUIElementCreateSystemWide(), scope: "system")
    }

    private static func focusedElement(in root: AXUIElement, scope: String) -> AXUIElement? {
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            trace("focus.\(scope).\(status.rawValue)")
            return nil
        }
        return unsafeBitCast(focused, to: AXUIElement.self)
    }

    nonisolated static func trace(_ stage: String) {
        #if DEBUG || SEVEN_DEVELOPMENT
        Task {
            await FileDiagnosticLogger.shared.record(.info, "input_replacement_capture", metadata: ["error_type": stage])
        }
        #endif
    }

    private static func value(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
}
