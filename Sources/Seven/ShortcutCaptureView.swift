import SwiftUI
import AppKit
import Carbon
import CoreGraphics

enum ShortcutCaptureAttempt:Equatable {
    case saved([String])
    case failed(String)
}

/// 两类录入共用展示和事件监听，仅校验/保存策略不同。
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
    func record(_ event:NSEvent)->ShortcutCaptureAttempt {
        switch self {
        case .combination(let manager):
            guard let shortcut=KeyboardShortcut(event:event) else{return .failed(L10n.text("includeOrAndTryADifferentShortcut"))}
            return manager.update(shortcut) ? .saved(shortcut.keyLabels):.failed(manager.statusMessage)
        case .tool(let action,let preferences):
            if let problem=preferences.recordingProblem(event,for:action) {return .failed(problem)}
            guard let key=event.charactersIgnoringModifiers?.lowercased(),preferences.setKey(key,for:action) else{return .failed(L10n.text("couldNotSaveThisShortcutTryAgain"))}
            return .saved([key.uppercased()])
        }
    }
}

/// 失败时左右轻晃。
private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: Design.ShortcutRecorder.shakeDistance * sin(animatableData * .pi * 4), y: 0))
    }
}

/// 录制快捷键：以键帽显示示例、实时修饰键与结果；在弹出框内校验。
/// 录制期间暂停Seven全部全局快捷键，使按键能到达这里。
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
    /// Seven的全部快捷键（含正在录制的这一个），录制期间统一暂停。
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
    /// 检测到普通键已按下、但这么久仍未收到按键事件时，判定为被其他应用拦截。
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
            }
            .padding(.horizontal, Design.Space.xl)
            .padding(.top, Design.Space.l)
            .padding(.bottom, Design.Space.m)
            ThemedDivider()
            HStack(spacing: Design.Space.s) {
                Text(action).font(Design.Text.bodyDigits.font)
                Spacer()
                Text(L10n.text("cancel")).font(Design.Text.body.font).foregroundStyle(ThemeStyle.inkSecondary)
                Keycap(label: "Esc", style: .normal, text: .note)
            }
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.s)
        }
        .frame(width: Design.ShortcutRecorder.width)
        .onAppear(perform: begin)
        .onDisappear(perform: end)
    }

    @ViewBuilder
    private var keycaps: some View {
        switch result {
        case .saved(let keys):
            KeycapRow(keys: keys, style: .accent, text: .content)
        case .failed, nil:
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

    private func begin() {
        allManagers.forEach { $0.suspend() }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            if case .saved = result { return event }
            let wasHolding = !heldModifiers.isEmpty
            heldModifiers = Self.modifierKeys(for: event.modifierFlags)
            if !wasHolding, !heldModifiers.isEmpty {
                // 开始新的一次尝试：清除上一次的结果与提示。
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
            if case .saved = result { return nil }
            // 忽略Seven自己模拟的按键（例如划词时模拟的 ⌘C），只录制用户真实按下的组合。
            if SelectionReader.isSynthetic(event) { return nil }
            if event.keyCode == UInt16(kVK_Escape) { dismiss(); return nil }
            interceptWatch?.cancel()
            interceptWatch = nil
            showsInterceptedHint = false
            switch target.record(event) {
            case .saved(let keys):
                result = .saved(keys)
                closeTask=Task { @MainActor in
                    try? await Task.sleep(for:.seconds(Self.closeDelay))
                    if !Task.isCancelled {dismiss()}
                }
            case .failed(let message):fail(message)
            }
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

    /// 按住修饰键期间，只要物理键盘上出现过普通键按下，而其后 200 毫秒内没有收到按键事件，
    /// 就说明该组合被其他应用或系统拦截（轻敲也算，不要求一直按住）。读取不到按键状态时不提示。
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

    /// 修饰键（含 Fn、Caps Lock）的虚拟键码，检测普通键时排除。
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
