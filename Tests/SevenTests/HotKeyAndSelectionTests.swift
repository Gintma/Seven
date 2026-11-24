import AppKit
import ApplicationServices
import Carbon
import XCTest
@testable import Seven

final class HotKeyAndSelectionTests: XCTestCase {
    func testShortcutRejectsUnmodifiedKey() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "d",
            charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2
        ))
        XCTAssertNil(KeyboardShortcut(event: event))
    }

    func testShortcutCapturesModifiersAndLabel() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option, .shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: "D",
            charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2
        ))
        XCTAssertEqual(KeyboardShortcut(event: event)?.displayName, "⌥⇧D")
    }

    func testCommandMConflictsWithSystemShortcut() {
        let shortcut = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_M),
            carbonModifiers: UInt32(cmdKey),
            keyLabel: "M"
        )

        XCTAssertTrue(shortcut.conflictsWithSystemShortcut)
        XCTAssertFalse(KeyboardShortcut.selectionDefault.conflictsWithSystemShortcut)
    }

    @MainActor
    func testStoredSystemShortcutFallsBackToDefault() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reserved = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_M),
            carbonModifiers: UInt32(cmdKey),
            keyLabel: "M"
        )
        defaults.set(try JSONEncoder().encode(reserved), forKey: "selectionHotKey.v1")

        let manager = HotKeyManager(defaults: defaults)

        XCTAssertEqual(manager.shortcut, .selectionDefault)
    }

    @MainActor
    func testInputShortcutUsesConfiguredDefaultAndIndependentStorage() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = HotKeyManager(
            defaults: defaults, storageKey: "inputHotKey.v1", defaultShortcut: .inputDefault,
            identifierID: 3, actionLabel: "输入翻译"
        )

        XCTAssertEqual(manager.shortcut, KeyboardShortcut.inputDefault)
        XCTAssertNotNil(defaults.data(forKey: "inputHotKey.v1"))
        XCTAssertNil(defaults.data(forKey: "selectionHotKey.v1"))
        XCTAssertNotEqual(KeyboardShortcut.inputDefault, .selectionDefault)
        XCTAssertNotEqual(KeyboardShortcut.inputDefault, .screenshotDefault)
    }

    @MainActor
    func testShortcutAlreadyUsedByAnotherSevenActionIsRejected() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = HotKeyManager(
            defaults: defaults, storageKey: "inputHotKey.v1", defaultShortcut: .inputDefault,
            identifierID: 3, actionLabel: "输入翻译"
        )
        let otherAction = LocalizedMessage.key("translateSelection")
        manager.conflictingAction = { $0 == .selectionDefault ? otherAction : nil }

        manager.update(.selectionDefault)

        XCTAssertEqual(manager.shortcut, .inputDefault, "被占用的组合不应保存")
        XCTAssertEqual(manager.statusMessage,
                       LocalizedMessage.key("thisShortcutIsAlreadyUsedForChoose", .message(otherAction)).text)
        XCTAssertNil(manager.problem, "录制中的失败只在弹出框提示，设置行不重复显示")
    }

    @MainActor
    func testResetConflictLocalizesTheOtherActionAfterLanguageChange() {
        let selection = HotKeyManager(defaults: nil, defaultShortcut: .selectionDefault, scope: .local)
        let input = HotKeyManager(defaults: nil, defaultShortcut: .inputDefault, scope: .local)
        let reassigned = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_G), carbonModifiers: UInt32(optionKey), keyLabel: "G")
        XCTAssertTrue(selection.update(reassigned))
        XCTAssertTrue(input.update(.selectionDefault))
        selection.conflictingAction = { candidate in
            input.shortcut == candidate ? .key("translateTypedText") : nil
        }

        let feedback = selection.reset()
        let expected = LocalizedMessage.key("couldNotRestoreTheDefault", .message(
            .key("thisShortcutIsAlreadyUsedForChoose", .message(.key("translateTypedText")))))
        XCTAssertEqual(feedback, expected)
        let chinese = L10n.$languageOverride.withValue(.simplifiedChinese) { feedback?.text }
        let english = L10n.$languageOverride.withValue(.english) { feedback?.text }
        XCTAssertNotNil(chinese)
        XCTAssertNotNil(english)
        XCTAssertNotEqual(chinese, english)
        XCTAssertEqual(selection.shortcut, reassigned)
        XCTAssertNil(selection.problem)
    }

    func testShiftOnlyCombinationsAreNotGlobalShortcuts() throws {
        let shiftA = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(shiftKey), keyLabel: "A")
        XCTAssertFalse(shiftA.hasPrimaryModifier, "⇧A 会在输入大写字母时被误触发")
        XCTAssertTrue(KeyboardShortcut.inputDefault.hasPrimaryModifier)

        func event(_ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                             isARepeat: false, keyCode: UInt16(kVK_ANSI_A))
        }
        XCTAssertNil(KeyboardShortcut(event: try XCTUnwrap(event(.shift))))
        XCTAssertEqual(KeyboardShortcut(event: try XCTUnwrap(event([.shift, .option])))?.displayName, "⌥⇧A")
        XCTAssertEqual(ShortcutCaptureView.modifierKeys(for: [.command, .option, .control]), ["⌃", "⌥", "⌘"])
    }

    @MainActor
    func testSavedShiftOnlyShortcutFallsBackToDefault() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let shiftA = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(shiftKey), keyLabel: "A")
        defaults.set(try JSONEncoder().encode(shiftA), forKey: "inputHotKey.v1")

        let manager = HotKeyManager(defaults: defaults, storageKey: "inputHotKey.v1",
                                    defaultShortcut: .inputDefault, identifierID: 3, actionLabel: "输入翻译")

        XCTAssertEqual(manager.shortcut, .inputDefault)
        XCTAssertFalse(manager.update(shiftA))
        XCTAssertEqual(manager.statusMessage, L10n.text("includeOrAndTryADifferentShortcut"))
    }

    @MainActor
    func testRegistrationFailureKeepsItsMessageAndSuspendResumeReregisters() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rare = KeyboardShortcut(keyCode: UInt32(kVK_F18),
                                    carbonModifiers: UInt32(controlKey | optionKey | cmdKey), keyLabel: "F18")
        let holder = HotKeyManager(defaults: defaults, storageKey: "test.holder", defaultShortcut: rare,
                                   identifierID: 90, actionLabel: "占用方")
        holder.start()
        defer { holder.stop() }
        XCTAssertTrue(holder.isRegistered)

        let other = HotKeyManager(defaults: defaults, storageKey: "test.other", defaultShortcut: .inputDefault,
                                  identifierID: 91, actionLabel: "输入翻译")
        XCTAssertFalse(other.update(rare), "同一组合不能重复注册")
        XCTAssertEqual(other.statusMessage, L10n.text("anotherAppAlreadyUsesThisShortcutChoose"))
        XCTAssertNotEqual(other.shortcut, rare)
        other.stop()

        holder.suspend()
        XCTAssertFalse(holder.isRegistered, "录制期间应暂停注册")
        holder.resume()
        XCTAssertTrue(holder.isRegistered, "录制结束后应恢复注册")
    }

    @MainActor
    func testHotKeysNeverFireWhileRecordingEvenAfterRegisteringNewCombination() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = HotKeyManager(defaults: defaults, storageKey: "test.recording", defaultShortcut: .selectionDefault,
                                    identifierID: 92, actionLabel: "划词翻译")
        var fired = 0
        manager.onHotKey = { fired += 1 }

        manager.suspend()  // 从未注册成功也必须进入暂停
        manager.fire()
        XCTAssertEqual(fired, 0)

        let rare = KeyboardShortcut(keyCode: UInt32(kVK_F17),
                                    carbonModifiers: UInt32(controlKey | optionKey | cmdKey), keyLabel: "F17")
        XCTAssertTrue(manager.update(rare), "录制中可以注册新组合")
        manager.fire()
        XCTAssertEqual(fired, 0, "录制窗口未关闭前，新注册的组合也不应触发（否则会模拟 ⌘C 被录进来）")

        manager.resume()
        manager.fire()
        XCTAssertEqual(fired, 1, "录制结束后恢复触发")
        manager.stop()
    }

    func testRecordingIgnoresSevenSyntheticKeystrokes() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        let synthetic = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true))
        synthetic.flags = .maskCommand
        synthetic.setIntegerValueField(.eventSourceUserData, value: SelectionReader.syntheticEventMarker)
        XCTAssertTrue(SelectionReader.isSynthetic(try XCTUnwrap(NSEvent(cgEvent: synthetic))))

        let real = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_D), keyDown: true))
        real.flags = .maskAlternate
        XCTAssertFalse(SelectionReader.isSynthetic(try XCTUnwrap(NSEvent(cgEvent: real))))
    }

    @MainActor
    func testRegistrationProblemAndResetFeedbackHaveSeparateLifetimes() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let taken = KeyboardShortcut(keyCode: UInt32(kVK_F16),
                                     carbonModifiers: UInt32(controlKey | optionKey | cmdKey), keyLabel: "F16")
        let holder = HotKeyManager(defaults: defaults, storageKey: "test.holder2", defaultShortcut: taken,
                                   identifierID: 93, actionLabel: "占用方")
        holder.start()
        defer { holder.stop() }

        // 启动时组合已被占用：设置行应显示问题
        let starter = HotKeyManager(defaults: defaults, storageKey: "test.starter", defaultShortcut: taken,
                                    identifierID: 94, actionLabel: "输入翻译")
        starter.start()
        XCTAssertFalse(starter.isRegistered)
        XCTAssertEqual(starter.problem, L10n.text("anotherAppAlreadyUsesThisShortcutChoose"))
        starter.stop()

        // 恢复默认失败交给设置行处理，原先已注册的组合仍然有效。
        let other = HotKeyManager(defaults: defaults, storageKey: "test.other2", defaultShortcut: taken,
                                  identifierID: 95, actionLabel: "划词翻译")
        let free = KeyboardShortcut(keyCode: UInt32(kVK_F15),
                                    carbonModifiers: UInt32(controlKey | optionKey | cmdKey), keyLabel: "F15")
        XCTAssertTrue(other.update(free))
        XCTAssertNil(other.problem)
        XCTAssertEqual(other.reset(), .key("couldNotRestoreTheDefault", .message(.key("anotherAppAlreadyUsesThisShortcutChoose"))))
        XCTAssertTrue(other.isRegistered)
        XCTAssertNil(other.problem)
        XCTAssertEqual(other.shortcut, free, "恢复失败时保留原组合")
        other.stop()
    }

    func testShortcutSplitsIntoKeycapsInStandardOrder() {
        let all = KeyboardShortcut(keyCode: UInt32(kVK_Space),
                                   carbonModifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey), keyLabel: "Space")
        XCTAssertEqual(all.keyLabels, ["⌃", "⌥", "⇧", "⌘", "Space"])
        XCTAssertEqual(all.keyLabels.joined(), all.displayName)
        XCTAssertEqual(ShortcutCaptureView.modifierKeys(for: [.command, .option]), ["⌥", "⌘"])
    }

    func testCommandLetterAndSystemScreenshotCombinationsAreReserved() {
        func shortcut(_ key: Int, _ modifiers: Int) -> KeyboardShortcut {
            KeyboardShortcut(keyCode: UInt32(key), carbonModifiers: UInt32(modifiers), keyLabel: "?")
        }
        XCTAssertTrue(shortcut(kVK_ANSI_C, cmdKey).conflictsWithSystemShortcut, "⌘C")
        XCTAssertTrue(shortcut(kVK_ANSI_V, cmdKey).conflictsWithSystemShortcut, "⌘V")
        XCTAssertTrue(shortcut(kVK_ANSI_4, cmdKey | shiftKey).conflictsWithSystemShortcut, "⌘⇧4")
        XCTAssertFalse(shortcut(kVK_ANSI_C, optionKey).conflictsWithSystemShortcut, "⌥C")
        XCTAssertFalse(shortcut(kVK_ANSI_2, cmdKey).conflictsWithSystemShortcut, "⌘2")
        XCTAssertFalse(shortcut(kVK_ANSI_C, cmdKey | optionKey).conflictsWithSystemShortcut, "⌘⌥C")
    }

    @MainActor
    func testScreenshotShortcutUsesIndependentStorage() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = HotKeyManager(
            defaults: defaults,
            storageKey: "screenshotHotKey.v1",
            defaultShortcut: .screenshotDefault,
            identifierID: 2,
            actionLabel: "截图翻译"
        )

        XCTAssertEqual(manager.shortcut, .screenshotDefault)
        XCTAssertNotNil(defaults.data(forKey: "screenshotHotKey.v1"))
        XCTAssertNil(defaults.data(forKey: "selectionHotKey.v1"))
    }

    func testPasteboardSnapshotRestoresMultipleTypes() throws {
        let pasteboard = NSPasteboard(name: .init("SevenTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("before", forType: .string))
        XCTAssertTrue(item.setData(Data("<b>before</b>".utf8), forType: .html))
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("temporary", forType: .string))
        let copiedVersion = pasteboard.changeCount

        XCTAssertTrue(snapshot.restore(to: pasteboard, ifUnchangedSince: copiedVersion))
        XCTAssertEqual(pasteboard.string(forType: .string), "before")
        XCTAssertEqual(pasteboard.data(forType: .html), Data("<b>before</b>".utf8))
    }

    func testPasteboardSnapshotDoesNotOverwriteNewerCopy() {
        let pasteboard = NSPasteboard(name: .init("SevenTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let oldVersion = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString("user copied something new", forType: .string)

        XCTAssertFalse(snapshot.restore(to: pasteboard, ifUnchangedSince: oldVersion))
        XCTAssertEqual(pasteboard.string(forType: .string), "user copied something new")
    }

    func testCollapsedTextSelectionSkipsClipboardFallback() async throws {
        var caret = CFRange(location: 4, length: 0)
        let range = try XCTUnwrap(AXValueCreate(.cfRange, &caret))
        let reader = SelectionReader { _, attribute in
            switch attribute {
            case kAXRoleAttribute: return kAXTextAreaRole as CFString
            case kAXSelectedTextRangeAttribute: return range
            default: return nil
            }
        }

        var attempts = 0
        do {
            _ = try await reader.readSelection(focused: AXUIElementCreateSystemWide(), applicationPID: nil) {
                attempts += 1
                throw SelectionReadError.copyTimedOut
            }
            XCTFail("A caret without a selection should report an empty selection")
        } catch {
            XCTAssertEqual(error as? SelectionReadError, .noSelection)
        }
        XCTAssertEqual(attempts, 0)
    }

    func testUnknownSelectionDoesNotTranslateTheCopyCommandResult() async throws {
        let reader = SelectionReader { _, attribute in
            attribute == kAXRoleAttribute ? kAXTextAreaRole as CFString : nil
        }
        var copies = 0
        do {
            _ = try await reader.readSelection(focused: AXUIElementCreateSystemWide(), applicationPID: nil) {
                copies += 1
                return "Seven"
            }
            XCTFail("An unconfirmed selection must not become a translation source")
        } catch {
            XCTAssertEqual(error as? SelectionReadError, .noSelection)
        }
        XCTAssertEqual(copies, 0)
    }

    func testWindowTextIsNotTheFocusedDocumentSelection() async throws {
        let focused = AXUIElementCreateSystemWide()
        let window = AXUIElementCreateApplication(1)
        let reader = SelectionReader { element, attribute in
            if CFEqual(element, focused) {
                return attribute == kAXParentAttribute ? window : nil
            }
            switch attribute {
            case kAXRoleAttribute: return kAXWindowRole as CFString
            case kAXSelectedTextAttribute: return "Seven" as CFString
            default: return nil
            }
        }
        do {
            _ = try await reader.readSelection(focused: focused, applicationPID: nil) {
                XCTFail("A window label has no copyable text selection")
                return "Seven"
            }
            XCTFail("A window label must not become a translation source")
        } catch {
            XCTAssertEqual(error as? SelectionReadError, .noSelection)
        }
    }

    func testSelectionInAnUnfocusedControlDoesNotBecomeTheSource() async throws {
        let targetPID = ProcessInfo.processInfo.processIdentifier
        let focused = AXUIElementCreateApplication(targetPID)
        let window = AXUIElementCreateApplication(1)
        let unrelatedTextField = AXUIElementCreateSystemWide()
        let reader = SelectionReader { element, attribute in
            if CFEqual(element, focused) {
                return attribute == kAXFocusedWindowAttribute ? window : nil
            }
            if CFEqual(element, window) {
                return attribute == kAXChildrenAttribute ? [unrelatedTextField] as CFArray : nil
            }
            switch attribute {
            case kAXRoleAttribute: return kAXTextFieldRole as CFString
            case kAXSelectedTextAttribute: return "Unrelated text" as CFString
            default: return nil
            }
        }
        do {
            _ = try await reader.readSelection(focused: focused, applicationPID: targetPID) {
                XCTFail("No text selection was confirmed on the focused element")
                return ""
            }
            XCTFail("An unfocused control must not become the translation source")
        } catch {
            XCTAssertEqual(error as? SelectionReadError, .noSelection)
        }
    }

    func testAdditionalSelectionStillUsesClipboardFallback() async throws {
        var caret = CFRange(location: 4, length: 0)
        var selection = CFRange(location: 1, length: 2)
        let caretValue = try XCTUnwrap(AXValueCreate(.cfRange, &caret))
        let selectionValue = try XCTUnwrap(AXValueCreate(.cfRange, &selection))
        let reader = SelectionReader { _, attribute in
            switch attribute {
            case kAXRoleAttribute: return kAXTextAreaRole as CFString
            case kAXSelectedTextRangeAttribute: return caretValue
            case kAXSelectedTextRangesAttribute: return [caretValue, selectionValue] as CFArray
            default: return nil
            }
        }
        let result = try await reader.readSelection(focused: AXUIElementCreateSystemWide(), applicationPID: nil) {
            "Another selection"
        }
        XCTAssertEqual(result, SelectedText(text: "Another selection", appKitBounds: nil))
    }

    func testFocusedWebDocumentCanProvideSelectedText() async throws {
        let focused = AXUIElementCreateSystemWide()
        let document = AXUIElementCreateApplication(1)
        let reader = SelectionReader { element, attribute in
            if CFEqual(element, focused) {
                return attribute == kAXParentAttribute ? document : nil
            }
            switch attribute {
            case kAXRoleAttribute: return "AXWebArea" as CFString
            case kAXSelectedTextAttribute: return "Seven" as CFString
            default: return nil
            }
        }
        let result = try await reader.readSelection(focused: focused, applicationPID: nil) {
            XCTFail("The web document supplies selected text directly")
            return ""
        }
        XCTAssertEqual(result, SelectedText(text: "Seven", appKitBounds: nil))
    }

    func testReportedSelectionKeepsWaitingForSlowClipboardText() async throws {
        let pasteboard = NSPasteboard(name: .init("SevenTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Existing clipboard", forType: .string))
        let copy = Task {
            try await Task.sleep(for: .milliseconds(1_100))
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString("Copied after a delay", forType: .string))
        }
        defer { copy.cancel() }
        let result = try await SelectionReader().readUsingCopyFallback(
            pasteboard: pasteboard, targetIsFrontmost: { true },
            invokeMenuCopy: { true }, sendCopyShortcut: { false }
        )
        try await copy.value
        XCTAssertEqual(result, "Copied after a delay")
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing clipboard")
    }

    func testSelectionTextDecoderHandlesUTF16RangesAndInvalidReplacementText() {
        let value = "A😀中文B" as NSString
        let range = value.range(of: "😀中文")

        XCTAssertEqual(
            SelectionTextDecoder.substring(
                value as String,
                utf16Range: CFRange(location: range.location, length: range.length)
            ),
            "😀中文"
        )
        XCTAssertEqual(SelectionTextDecoder.normalized("\0  café  \n"), "café")
        XCTAssertNil(SelectionTextDecoder.normalized("bad \u{FFFD} text"))
    }

    func testSelectionTextDecoderJoinsMultiplePasteboardItems() {
        let pasteboard = NSPasteboard(name: .init("SevenTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let first = NSPasteboardItem()
        let second = NSPasteboardItem()
        XCTAssertTrue(first.setString("第一段", forType: .string))
        XCTAssertTrue(second.setString("second paragraph", forType: .string))
        XCTAssertTrue(pasteboard.writeObjects([first, second]))

        XCTAssertEqual(SelectionTextDecoder.text(from: pasteboard), "第一段\nsecond paragraph")
    }

    func testAccessibilityCoordinateConversionUsesPrimaryScreenTopEdge() {
        let accessibilityRect = CGRect(x: 120, y: 80, width: 240, height: 32)

        XCTAssertEqual(
            AccessibilityCoordinateSpace.appKitRect(
                fromAccessibility: accessibilityRect,
                primaryScreenMaxY: 900
            ),
            CGRect(x: 120, y: 788, width: 240, height: 32)
        )
    }

}
