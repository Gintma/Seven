import AppKit
import Carbon
import Foundation

struct KeyboardShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyLabel: String

    static let selectionDefault = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_D),
        carbonModifiers: UInt32(optionKey),
        keyLabel: "D"
    )
    /// Input translation defaults to ⌥A, adjacent to screenshot (⌥S) and selection translation (⌥D).
    static let inputDefault = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_A),
        carbonModifiers: UInt32(optionKey),
        keyLabel: "A"
    )
    static let replacementDefault = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_T), carbonModifiers: UInt32(controlKey | optionKey), keyLabel: "T"
    )
    static let screenshotDefault = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_S),
        carbonModifiers: UInt32(optionKey),
        keyLabel: "S"
    )
    static let regionCaptureDefault = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(controlKey | optionKey), keyLabel: "S"
    )
    static let ocrCaptureDefault = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_O), carbonModifiers: UInt32(controlKey | optionKey), keyLabel: "O"
    )

    /// Splits into individual keys in display order for rendering keycaps, e.g. ["⌥", "D"].
    var keyLabels: [String] {
        var keys: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { keys.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { keys.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { keys.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { keys.append("⌘") }
        return keys + [keyLabel]
    }

    var displayName: String {
        var value = ""
        if carbonModifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + keyLabel
    }

    /// Global shortcuts must include ⌘, ⌥, or ⌃: combinations with only ⇧ would misfire while typing uppercase letters.
    var hasPrimaryModifier: Bool {
        carbonModifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    /// ⌘ + letter combos are standard editing and window commands across apps (⌘C, ⌘V, ⌘Z, ...), and ⌘⇧3/4/5 are system screenshot shortcuts;
    /// registering them as global hotkeys would break those commands in every app.
    var conflictsWithSystemShortcut: Bool {
        if carbonModifiers == UInt32(cmdKey) {
            let reserved = [UInt32(kVK_ANSI_Comma), UInt32(kVK_Space), UInt32(kVK_Tab)]
            return Self.letterKeyCodes.contains(keyCode) || reserved.contains(keyCode)
        }
        if carbonModifiers == UInt32(cmdKey | shiftKey) {
            return [UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_Z)].contains(keyCode)
        }
        return false
    }

    private static let letterKeyCodes: Set<UInt32> = Set([
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
        kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P,
        kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
        kVK_ANSI_Y, kVK_ANSI_Z
    ].map(UInt32.init))

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        let ignored = event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard let label = Self.label(for: UInt32(event.keyCode), characters: ignored) else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers, keyLabel: label)
    }

    private static func label(for keyCode: UInt32, characters: String) -> String? {
        let special: [UInt32: String] = [
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩",
            UInt32(kVK_Tab): "⇥", UInt32(kVK_Delete): "⌫",
            UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_Escape): "Esc",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_Home): "Home", UInt32(kVK_End): "End",
            UInt32(kVK_PageUp): "Page Up", UInt32(kVK_PageDown): "Page Down",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12"
        ]
        if let value = special[keyCode] { return value }
        guard !characters.isEmpty, characters.count <= 2 else { return nil }
        return characters
    }
}

private let sevenHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr, identifier.id == manager.identifierID else {
        return OSStatus(eventNotHandledErr)
    }
    Task { @MainActor in manager.fire() }
    return noErr
}

@MainActor
final class HotKeyManager: ObservableObject {
    static let regionCaptureStorageKey = "regionCaptureHotKey.v1"

    static func regionCapture(defaults: UserDefaults? = .standard, scope: Scope = .global) -> HotKeyManager {
        HotKeyManager(defaults: defaults, storageKey: regionCaptureStorageKey, defaultShortcut: .regionCaptureDefault,
                      identifierID: 7, actionLabel: "截图", allowsUnset: true, scope: scope)
    }

    @Published private(set) var shortcut: KeyboardShortcut
    @Published private var status = LocalizedMessage.verbatim("")
    var statusMessage: String { status.text }
    /// The currently saved shortcut failed to register. Feedback for recording and restoring defaults is handled by the initiating UI.
    @Published private var problemMessage: LocalizedMessage?
    var problem: String? { problemMessage?.text }
    @Published private(set) var isRegistered = false
    @Published private(set) var isEnabled = true
    var reservesShortcut: Bool { isEnabled && (!usesImplicitDefault || problemMessage == nil) }
    let allowsUnset: Bool
    var onHotKey: (() -> Void)?
    /// Keeps the localized message for the conflicting action; settings rows resolve display names when rendering errors.
    var conflictingAction: ((KeyboardShortcut) -> LocalizedMessage?)?

    enum Scope {case global,local}
    private let scope:Scope
    private let defaults: UserDefaults?
    private let storageKey: String
    let defaultShortcutForDisplay: KeyboardShortcut?
    private var usesImplicitDefault = false
    fileprivate let identifierID: UInt32
    private let actionLabel: String
    private var hotKeyRef: EventHotKeyRef?
    private var isSuspended = false
    private var eventHandlerRef: EventHandlerRef?

    init(
        defaults: UserDefaults? = .standard,
        storageKey: String = "selectionHotKey.v1",
        defaultShortcut: KeyboardShortcut? = nil,
        identifierID: UInt32 = 1,
        actionLabel: String = "划词翻译",
        allowsUnset: Bool = false,
        scope:Scope = .global
    ) {
        self.scope=scope
        self.defaults = defaults
        self.storageKey = storageKey
        let defaultShortcut = defaultShortcut ?? (allowsUnset ? nil : .selectionDefault)
        self.defaultShortcutForDisplay = defaultShortcut
        self.identifierID = identifierID
        self.actionLabel = actionLabel
        self.allowsUnset = allowsUnset
        if let data = defaults?.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(KeyboardShortcut.self, from: data),
           !saved.conflictsWithSystemShortcut, saved.hasPrimaryModifier {
            shortcut = saved
        } else {
            shortcut = defaultShortcut ?? .selectionDefault
            if allowsUnset {
                // Missing value means first run; an explicitly cleared false must persist across restarts.
                let explicitlyCleared = defaults?.object(forKey: storageKey) as? Bool == false
                isEnabled = defaultShortcut != nil && !explicitlyCleared
                usesImplicitDefault = isEnabled
            } else if let data = try? JSONEncoder().encode(shortcut) {
                defaults?.set(data, forKey: storageKey)
            }
        }
    }

    func start() {
        guard scope == .global else{return}
        guard eventHandlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(), sevenHotKeyHandler, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            status = .verbatim("无法安装全局快捷键监听（\(handlerStatus)）")
            return
        }
        if isEnabled, !registerCurrentShortcut() { problemMessage = status }
    }

    func stop() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        isRegistered = false
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        eventHandlerRef = nil
    }

    /// Returns whether saving succeeded; see statusMessage for failure details.
    @discardableResult
    func update(_ candidate: KeyboardShortcut) -> Bool {
        guard candidate.hasPrimaryModifier else {
            status = .key("includeOrAndTryADifferentShortcut")
            return false
        }
        guard !candidate.conflictsWithSystemShortcut else {
            status = .key("thisShortcutIsCommonlyUsedByMacOS")
            return false
        }
        if let other = conflictingAction?(candidate) {
            status = .key("thisShortcutIsAlreadyUsedForChoose", .message(other))
            return false
        }
        let wasEnabled = isEnabled
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        isRegistered = false
        if register(candidate) {
            shortcut = candidate; isEnabled = true
            usesImplicitDefault = false
            if let data = try? JSONEncoder().encode(candidate) { defaults?.set(data, forKey: storageKey) }
            status = "快捷键已保存"
            return true
        }
        let failure = status
        if wasEnabled, !registerCurrentShortcut() { problemMessage = status }
        status = failure
        return false
    }

    func clear() {
        guard allowsUnset else { return }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil; isRegistered = false; isEnabled = false
        usesImplicitDefault = false
        if defaultShortcutForDisplay != nil {
            defaults?.set(false, forKey: storageKey)
        } else {
            defaults?.removeObject(forKey: storageKey)
        }
        status = "未设置"; problemMessage = nil
    }
    @discardableResult
    func reset() -> LocalizedMessage? {
        guard let defaultShortcut = defaultShortcutForDisplay else { clear(); return nil }
        return update(defaultShortcut) ? nil : .key("couldNotRestoreTheDefault", .message(status))
    }

    /// Suspends hotkey registration during shortcut recording so keystrokes reach the recorder instead of triggering Seven's own actions.
    func suspend() {
        // Mark suspended even if registration currently failed (e.g. claimed by another app) so newly registered combos during recording cannot fire.
        isSuspended = true
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
        isRegistered = false
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        if isEnabled, hotKeyRef == nil, !registerCurrentShortcut() { problemMessage = status }
    }

    /// Suppresses all action triggers during shortcut recording, including combos newly registered mid-recording.
    func fire() {
        guard isEnabled, !isSuspended else { return }
        onHotKey?()
    }

    func matches(_ event:NSEvent)->Bool {
        guard isEnabled,!isSuspended,let value=KeyboardShortcut(event:event) else{return false}
        return value.keyCode == shortcut.keyCode && value.carbonModifiers == shortcut.carbonModifiers
    }

    private func registerCurrentShortcut() -> Bool {
        // Newly introduced default shortcuts must not hijack bindings already saved for other actions.
        if usesImplicitDefault, let other = conflictingAction?(shortcut) {
            status = .key("thisShortcutIsAlreadyUsedForChoose", .message(other))
            return false
        }
        return register(shortcut)
    }

    @discardableResult
    private func register(_ value: KeyboardShortcut) -> Bool {
        guard scope == .global else {problemMessage=nil;return true}
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x5356484B), id: identifierID) // SVHK
        let result = RegisterEventHotKey(
            value.keyCode, value.carbonModifiers, identifier,
            GetEventDispatcherTarget(), 0, &reference
        )
        guard result == noErr, let reference else {
            status = result == OSStatus(eventHotKeyExistsErr)
                ? .key("anotherAppAlreadyUsesThisShortcutChoose")
                : .key("couldNotRegisterTheShortcut", .text(String(result)))
            return false
        }
        hotKeyRef = reference
        isRegistered = true
        problemMessage = nil
        status = .verbatim("\(actionLabel)：\(value.displayName)")
        return true
    }
}
