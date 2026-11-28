import SwiftUI
import AppKit
import Carbon
import CoreGraphics

enum ShortcutCaptureAttempt:Equatable {
    case saved([String])
    case cleared
    case failed(String)

    var isComplete: Bool {
        switch self {
        case .saved, .cleared: return true
        case .failed: return false
        }
    }
}

/// Both recording modes share presentation and event monitoring, differing only in validation and save policies.
@MainActor enum ShortcutCaptureTarget {
    case combination(HotKeyManager)
    case tool(ScreenshotToolbarAction,ScreenshotToolbarPreferences)
    var currentKeys:[String] {
        switch self {
        case .combination(let manager):return manager.isEnabled ? manager.shortcut.keyLabels:[]
        case .tool(let action,let preferences):return [preferences.hint(action)]
        }
    }
    var isCombination:Bool {if case .combination=self {return true};return false}

    var canClear: Bool {
        guard case .combination(let manager) = self else { return false }
        return manager.allowsUnset && manager.isEnabled
    }

    var canRestore: Bool {
        switch self {
        case .combination(let manager):
            guard let shortcut = manager.defaultShortcutForDisplay else { return false }
            return !manager.isEnabled || manager.shortcut != shortcut
        case .tool(let action, let preferences):
            return action.acceptsKey && preferences.item(action).key != action.defaultKey
        }
    }

    func restore() -> ShortcutCaptureAttempt {
        switch self {
        case .combination(let manager):
            if let issue = manager.reset() { return .failed(issue.text) }
        case .tool(let action, let preferences):
            guard preferences.resetKey(action) else {
                return .failed(L10n.text("anotherActionUsesTheDefaultKeyChange"))
            }
        }
        return .saved(currentKeys)
    }

    func record(_ event:NSEvent)->ShortcutCaptureAttempt {
        switch self {
        case .combination(let manager):
            if event.keyCode == UInt16(kVK_Delete), canClear,
               event.modifierFlags.intersection([.command, .option, .control, .shift, .function]).isEmpty {
                manager.clear()
                return .cleared
            }
            guard let shortcut=KeyboardShortcut(event:event) else{return .failed(L10n.text("includeOrAndTryADifferentShortcut"))}
            return manager.update(shortcut) ? .saved(shortcut.keyLabels):.failed(manager.statusMessage)
        case .tool(let action,let preferences):
            if let problem=preferences.recordingProblem(event,for:action) {return .failed(problem)}
            guard let key=event.charactersIgnoringModifiers?.lowercased(),preferences.setKey(key,for:action) else{return .failed(L10n.text("couldNotSaveThisShortcutTryAgain"))}
            return .saved([key.uppercased()])
        }
    }
}

/// Gently shakes horizontally on failure.
private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: Design.ShortcutRecorder.shakeDistance * sin(animatableData * .pi * 4), y: 0))
    }
}

/// Shortcut recorder: displays examples, live modifiers, and results as keycaps, validating inside the popover.
/// Suspends all global Seven shortcuts during recording so key presses reach this view.
struct ShortcutCaptureView: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    @Environment(\.dismiss) private var dismiss
    let action: String
    let target:ShortcutCaptureTarget
    init(action:String,manager:HotKeyManager,allManagers:[HotKeyManager]) {
        self.action=action;target = .combination(manager);self.allManagers=allManagers
    }
    init(action:String,target:ShortcutCaptureTarget,allManagers:[HotKeyManager]) {
        self.action=action;self.target=target;self.allManagers=allManagers
    }
    /// All Seven shortcuts (including the one being recorded), suspended together during recording.
    let allManagers: [HotKeyManager]

    @State private var keyMonitor: Any?
    @State private var flagsMonitor: Any?
    @State private var heldModifiers: [String] = []
    @State private var result: ShortcutCaptureAttempt?
    @State private var closeTask:Task<Void,Never>?
    @State private var shakes: CGFloat = 0
    @State private var showsInterceptedHint = false
    @State private var interceptWatch: Task<Void, Never>?

    static let closeDelay = Design.Motion.settle
    /// If a regular key is detected as pressed and no key event arrives within this interval, assume another app intercepted it.
    static let interceptGrace: Duration = .milliseconds(200)

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Design.Space.s) {
                keycaps
                    .modifier(ShakeEffect(animatableData: shakes))
                    .frame(minHeight: Design.ShortcutRecorder.keycapsHeight)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityText)
                Text(statusLine)
                    .font(Design.Text.note.font)
                    .foregroundStyle(statusIsError ? ThemeStyle.error : ThemeStyle.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if target.canRestore, result?.isComplete != true {
                    Button(L10n.text("restoreDefault")) { finish(target.restore()) }
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, Design.Space.xl)
            .padding(.top, Design.Space.l)
            .padding(.bottom, Design.Space.m)
            ThemedDivider()
            HStack(spacing: Design.Space.s) {
                Text(action).font(Design.Text.bodyDigits.font).lineLimit(1)
                Spacer()
                if target.canClear, result?.isComplete != true {
                    keyHint("delete", key: "⌫")
                }
                keyHint("close", key: "Esc")
            }
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.s)
        }
        .frame(width: Design.ShortcutRecorder.width)
        .onAppear(perform: begin)
        .onDisappear(perform: end)
    }

    private func keyHint(_ titleKey: String, key: String) -> some View {
        HStack(spacing: Design.Space.xs) {
            Text(L10n.text(titleKey)).font(Design.Text.note.font).foregroundStyle(ThemeStyle.inkSecondary)
            Keycap(label: key, style: .normal, text: .note)
        }.fixedSize().accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var keycaps: some View {
        switch result {
        case .saved(let keys):
            KeycapRow(keys: keys, style: .accent, text: .content)
        case .cleared, .failed, nil:
            if heldModifiers.isEmpty {
                HStack(spacing: Design.Space.s) {
                    Text(L10n.text("current")).font(Design.Text.body.font).foregroundStyle(ThemeStyle.inkSecondary)
                    KeycapRow(keys: target.currentKeys.isEmpty ? [L10n.text("notSet")]:target.currentKeys, style: .placeholder, text: .content)
                }
            } else {
                HStack(spacing: Design.Keycap.spacing) {
                    KeycapRow(keys: heldModifiers, style: .normal, text: .content)
                    Keycap(label: "", style: .empty, text: .content)
                }
            }
        }
    }

    private var statusLine: String {
        switch result {
        case .saved: return L10n.text("saved")
        case .cleared: return L10n.text("notSet")
        case .failed(let message): return message
        case nil:
            return showsInterceptedHint
                ? L10n.text("anotherAppInterceptedThatShortcutTryA")
                : (target.isCombination ? L10n.text("pressAShortcutContainingOr"):L10n.text("press09OrAZOr"))
        }
    }

    private var statusIsError: Bool {
        if case .failed = result { return true }
        return false
    }

    private var accessibilityText: String {
        switch result {
        case .saved(let keys): return L10n.format("setTo", String(describing: keys.joined()))
        case .cleared: return L10n.text("notSet")
        case .failed(let message): return message
        case nil:
            return heldModifiers.isEmpty
                ? L10n.format("waitingForAShortcutCurrentShortcut", String(describing: target.currentKeys.joined()))
                : L10n.format("holding", String(describing: heldModifiers.joined()))
        }
    }

    private func fail(_ message: String) {
        result = .failed(message)
        NSSound.beep()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        withAnimation(.linear(duration: Design.Motion.standard)) { shakes += 1 }
    }

    private func finish(_ attempt: ShortcutCaptureAttempt) {
        switch attempt {
        case .cleared:
            result = attempt
            dismiss()
        case .saved:
            result = attempt
            closeTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.closeDelay))
                if !Task.isCancelled { dismiss() }
            }
        case .failed(let message):
            fail(message)
        }
    }

    private func begin() {
        allManagers.forEach { $0.suspend() }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            if result?.isComplete == true { return event }
            let wasHolding = !heldModifiers.isEmpty
            heldModifiers = Self.modifierKeys(for: event.modifierFlags)
            if !wasHolding, !heldModifiers.isEmpty {
                // Start a fresh attempt: clear the previous result and hint.
                result = nil
                showsInterceptedHint = false
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.intersection([.command, .option, .control]).isEmpty {
                interceptWatch?.cancel()
                interceptWatch = nil
            } else if target.isCombination,interceptWatch == nil {
                interceptWatch = Task { @MainActor in await watchForInterceptedKey() }
            }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if result?.isComplete == true { return nil }
            // Ignore key events simulated by Seven itself (such as ⌘C during text selection) so only real user keystrokes are recorded.
            if SelectionReader.isSynthetic(event) { return nil }
            if event.keyCode == UInt16(kVK_Escape) { dismiss(); return nil }
            interceptWatch?.cancel()
            interceptWatch = nil
            showsInterceptedHint = false
            finish(target.record(event))
            return nil
        }
    }

    private func end() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
        closeTask?.cancel();closeTask=nil
        interceptWatch?.cancel()
        interceptWatch = nil
        allManagers.forEach { $0.resume() }
    }

    /// While modifiers are held, if any regular key was physically pressed on the keyboard and no key event arrives within 200 ms,
    /// conclude the combination was intercepted by another app or the system (quick taps count; holding is not required). Stay silent if key state cannot be read.
    @MainActor
    private func watchForInterceptedKey() async {
        var seenAt: ContinuousClock.Instant?
        while !Task.isCancelled {
            let now = ContinuousClock.now
            if seenAt == nil, Self.isNonModifierKeyDown() { seenAt = now }
            if let seen = seenAt, seen.duration(to: now) >= Self.interceptGrace {
                if result == nil { showsInterceptedHint = true }
                seenAt = nil
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    /// Virtual key codes for modifier keys (including Fn and Caps Lock), excluded when detecting regular key presses.
    private static let modifierKeyCodes: Set<CGKeyCode> = Set([
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
        kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function
    ].map { CGKeyCode($0) })

    static func isNonModifierKeyDown() -> Bool {
        (0..<128).contains { code in
            let key = CGKeyCode(code)
            return !modifierKeyCodes.contains(key) && CGEventSource.keyState(.hidSystemState, key: key)
        }
    }

    static func modifierKeys(for flags: NSEvent.ModifierFlags) -> [String] {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var keys: [String] = []
        if flags.contains(.control) { keys.append("⌃") }
        if flags.contains(.option) { keys.append("⌥") }
        if flags.contains(.shift) { keys.append("⇧") }
        if flags.contains(.command) { keys.append("⌘") }
        return keys
    }
}
