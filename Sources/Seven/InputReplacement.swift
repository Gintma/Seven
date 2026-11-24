import AppKit
import ApplicationServices
import Carbon

/// 分开保存 AX 显示文字与原生选区坐标；链接/附件坐标不能直接套在展开文字上。
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

    /// 部分编辑器把占位内容暴露为 AXValue；实际字符数为零时不能把它当原文。
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

/// 原生全选之后，等待读取到真实选区，不把一次尚未刷新的 AX 读数当作用户修改。
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
        // 只有明确的无选区输入才能走整框路径，绝不把选区读取失败降级为全选。
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
            // 链接/附件的原生选区坐标不一定等于 AXValue 展开文字的 UTF-16 长度。
            // Command-A 的结果作为新基准，不以另一种文本表示推算它应该有多长。
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
        // 原生全选未产生选区时仍继续复制；两次无非空白结果按产品规则静默结束。
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

    /// 原生复制确认发生在联网之前；不把编辑器的可访问性名称或过期 AXValue 当成用户输入。
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

    /// 只记录固定阶段、错误分类及字数，后续复现可定位具体拦截点，不记录正文或链接。
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

    /// 原应用原生粘贴，保留撤销；不发 Enter，不激活或切换到其他应用。
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
        // 给原应用处理原生粘贴的时间；观察到预期结果才提早归还剪贴板，最多等待一秒。
        // 会话写回期间不取消租约，以免原应用尚未取值时就恢复旧剪贴板。
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(50))
            if outputMatches(text) { break }
        }
    }

    /// 将原生 Command 组合键发送到已验证的进程，用于全选、复制和粘贴。
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
        // 有些应用不返回应用级焦点；只接受同一前台进程的系统焦点。
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
