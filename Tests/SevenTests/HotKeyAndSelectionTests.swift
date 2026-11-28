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
    func testDefaultRegionCaptureCanBeClearedRestoredAndRecordedAfterRestart() throws {
        let defaults = try XCTUnwrap(isolatedDefaults())
        let storageKey = HotKeyManager.regionCaptureStorageKey
        let initial = HotKeyManager.regionCapture(defaults: defaults, scope: .local)

        XCTAssertTrue(initial.allowsUnset)
        XCTAssertTrue(initial.isEnabled)
        XCTAssertEqual(initial.shortcut.displayName, "⌃⌥S")
        XCTAssertNil(defaults.object(forKey: storageKey))

        initial.clear()
        XCTAssertFalse(initial.isEnabled)
        let cleared = HotKeyManager.regionCapture(defaults: defaults, scope: .local)
        XCTAssertFalse(cleared.isEnabled)

        XCTAssertNil(cleared.reset())
        let restored = HotKeyManager.regionCapture(defaults: defaults, scope: .local)
        XCTAssertTrue(restored.isEnabled)
        XCTAssertEqual(restored.shortcut, .regionCaptureDefault)

        restored.clear()
        let recording = HotKeyManager.regionCapture(defaults: defaults, scope: .local)
        let alternate = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_8), carbonModifiers: UInt32(controlKey | optionKey), keyLabel: "8")
        XCTAssertTrue(recording.update(alternate))
        let reopened = HotKeyManager.regionCapture(defaults: defaults, scope: .local)
        XCTAssertTrue(reopened.isEnabled)
        XCTAssertEqual(reopened.shortcut, alternate)
    }

    @MainActor
    func testImplicitShortcutLeavesConflictingSavedBindingAvailable() throws {
        let defaults = try XCTUnwrap(isolatedDefaults())
        let shortcut = KeyboardShortcut(keyCode: UInt32(kVK_F19), carbonModifiers: UInt32(controlKey | optionKey), keyLabel: "F19")
        let existing = HotKeyManager(defaults: defaults, storageKey: "test.existing", identifierID: 912)
        XCTAssertTrue(existing.update(shortcut))
        defer { existing.stop() }
        let new = HotKeyManager(defaults: defaults, storageKey: "test.new", defaultShortcut: shortcut,
                                identifierID: 913, allowsUnset: true)
        defer { new.stop() }
        let existingAction = LocalizedMessage.key("captureFullScreen")
        new.conflictingAction = { $0 == existing.shortcut ? existingAction : nil }

        new.start()
        XCTAssertTrue(existing.isRegistered)
        XCTAssertFalse(new.isRegistered)
        XCTAssertFalse(new.reservesShortcut)
        XCTAssertTrue(existing.reservesShortcut)
        XCTAssertEqual(new.problem, LocalizedMessage.key("thisShortcutIsAlreadyUsedForChoose", .message(existingAction)).text)
        XCTAssertNil(defaults.object(forKey: "test.new"))
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

        manager.suspend()  // Must enter paused state even if registration never succeeded
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

        // Combination already taken at launch: settings row should show an issue
        let starter = HotKeyManager(defaults: defaults, storageKey: "test.starter", defaultShortcut: taken,
                                    identifierID: 94, actionLabel: "输入翻译")
        starter.start()
        XCTAssertFalse(starter.isRegistered)
        XCTAssertEqual(starter.problem, L10n.text("anotherAppAlreadyUsesThisShortcutChoose"))
        starter.stop()

        // Delegate reset-to-default failure to the settings row while keeping the previously registered combination active.
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
        let reader = SelectionReader(attribute: { _, attribute in
            switch attribute {
            case kAXRoleAttribute: return kAXTextAreaRole as CFString
            case kAXSelectedTextRangeAttribute: return range
            default: return nil
            }
        })

        var attempts = 0
        do {
            _ = try await reader.readSelection(focused: AXUIElementCreateSystemWide(), applicationPID: nil) { _, _ in
                attempts += 1
                throw SelectionReadError.copyTimedOut
            }
            XCTFail("A caret without a selection should report an empty selection")
        } catch {
            XCTAssertEqual(error as? SelectionReadError, .noSelection)
        }
        XCTAssertEqual(attempts, 0)
    }

    func testUnknownSelectionUsesOneShortCopyRouteAndReturnsItsText() async throws {
        let reader = SelectionReader(attribute: { _, _ in nil })
        let pasteboard = NSPasteboard(name: .init("SevenTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Before copy", forType: .string))
        var queries = 0
        var copies = 0
        let result = try await reader.readSelection(focused: nil, applicationPID: nil, copyMenuState: {
            queries += 1
            return .unknown
        }) { mode, _ in
            XCTAssertEqual(mode, .unknownSelection)
            return try await reader.readUsingCopyFallback(
                pasteboard: pasteboard, mode: mode, targetIsFrontmost: { true },
                invokeMenuCopy: { false },
                sendCopyShortcut: {
                    copies += 1
                    pasteboard.clearContents()
                    return pasteboard.setString("Selected in a custom view", forType: .string)
                }
            )
        }
        XCTAssertEqual(result.text, "Selected in a custom view")
        XCTAssertEqual(queries, 1)
        XCTAssertEqual(copies, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "Before copy")
    }

    func testDisabledCopyMenuEndsUnknownSelectionBeforeCopy() async throws {
        let reader = SelectionReader(attribute: { _, _ in nil })
        var queries = 0
        do {
            _ = try await reader.readSelection(focused: nil, applicationPID: nil, copyMenuState: {
                queries += 1
                return .disabled
            }) { _, _ in
                XCTFail("A disabled copy command must not start copying")
                return ""
            }
            XCTFail("A disabled copy command should end selection reading")
        } catch {
            XCTAssertEqual(error as? SelectionReadError, .noSelection)
        }
        XCTAssertEqual(queries, 1)
    }

    func testCopyMenuQueryDistinguishesDisabledEnabledAndUnavailable() {
        let application = AXUIElementCreateApplication(1)
        let menuBar = AXUIElementCreateApplication(2)
        let command = AXUIElementCreateApplication(3)
        for isEnabled: Bool? in [false, true, nil] {
            let reader = SelectionReader(attribute: { element, name in
                if CFEqual(element, application) {
                    return name == kAXMenuBarAttribute ? menuBar : nil
                }
                if CFEqual(element, menuBar) {
                    return name == kAXChildrenAttribute ? [command] as CFArray : nil
                }
                switch name {
                case kAXRoleAttribute: return kAXMenuItemRole as CFString
                case kAXMenuItemCmdCharAttribute: return "C" as CFString
                case kAXMenuItemCmdModifiersAttribute: return NSNumber(value: 0)
                case kAXEnabledAttribute: return isEnabled.map(NSNumber.init(value:))
                default: return nil
                }
            })
            switch (isEnabled, reader.copyMenuState(application: application, timeout: 1)) {
            case (false?, .disabled), (nil, .unknown):
                break
            case (true?, .enabled(let item)):
                XCTAssertTrue(CFEqual(item, command))
            default:
                XCTFail("Copy availability must preserve a missing enabled attribute as unknown")
            }
        }

        let reader = SelectionReader(attribute: { _, _ in
            XCTFail("An exhausted query budget must not make any AX calls")
            return nil
        })
        guard case .unknown = reader.copyMenuState(application: application, timeout: 0) else {
            XCTFail("An exhausted query budget must leave copy availability unknown")
            return
        }
    }

    func testNonTextObjectSkipsCopyEvenWithReportedText() async throws {
        let reader = SelectionReader(attribute: { _, name in
            switch name {
            case kAXRoleAttribute: return kAXRowRole as CFString
            case kAXSelectedTextAttribute: return "An object name" as CFString
            case kAXSelectedTextMarkerRangeAttribute: return NSNumber(value: 1)
            default: return nil
            }
        })
        do {
            _ = try await reader.readSelection(focused: AXUIElementCreateSystemWide(), applicationPID: nil, copyMenuState: {
                XCTFail("A selected row is not a text selection")
                return .unknown
            }) { _, _ in
                XCTFail("An object selection cannot start copying")
                return ""
            }
            XCTFail("An object name cannot become a translation source")
        } catch {
            XCTAssertEqual(error as? SelectionReadError, .noSelection)
        }
    }

    func testFocusedRenameFieldUsesItsSelectionInsideAnObjectRow() async throws {
        let focused = AXUIElementCreateSystemWide()
        let row = AXUIElementCreateApplication(1)
        let reader = SelectionReader(attribute: { element, name in
            if CFEqual(element, row) {
                return name == kAXRoleAttribute ? kAXRowRole as CFString : nil
            }
            switch name {
            case kAXRoleAttribute: return kAXTextFieldRole as CFString
            case kAXSelectedTextAttribute: return "Selected rename text" as CFString
            case kAXParentAttribute: return row
            default: return nil
            }
        })
        let result = try await reader.readSelection(focused: focused, applicationPID: nil) { _, _ in
            XCTFail("The rename field supplies text directly")
            return ""
        }
        XCTAssertEqual(result.text, "Selected rename text")
    }

    func testUnknownCopyTimesOutWithoutRetryingOrChangingExistingClipboard() async throws {
        let pasteboard = NSPasteboard(name: .init("SevenTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Existing clipboard", forType: .string))
        var copies = 0
        let started = ContinuousClock.now
        do {
            _ = try await SelectionReader().readUsingCopyFallback(
                pasteboard: pasteboard, mode: .unknownSelection, targetIsFrontmost: { true },
                invokeMenuCopy: { false }, sendCopyShortcut: { copies += 1; return true }
            )
            XCTFail("The clipboard did not receive text")
        } catch {
            XCTAssertEqual(error as? SelectionReadError, .copyTimedOut)
        }
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(1_400))
        XCTAssertEqual(copies, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing clipboard")
    }

    func testCopyRejectsMixedFileAndPlainTextAndRestoresClipboard() async throws {
        let pasteboard = NSPasteboard(name: .init("SevenTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Before copy", forType: .string))
        do {
            _ = try await SelectionReader().readUsingCopyFallback(
                pasteboard: pasteboard, mode: .unknownSelection, targetIsFrontmost: { true },
                invokeMenuCopy: {
                    let file = NSPasteboardItem()
                    XCTAssertTrue(file.setString("file:///Example.app", forType: .fileURL))
                    XCTAssertTrue(file.setString("Example", forType: .string))
                    pasteboard.clearContents()
                    return pasteboard.writeObjects([file])
                }, sendCopyShortcut: { false }
            )
            XCTFail("A file name must not become a translation source")
        } catch {
            XCTAssertEqual(error as? SelectionReadError, .noSelection)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "Before copy")
    }

    func testMarkerLengthDeterminesCopyRoute() async throws {
        let start: [UInt8] = [1]
        let end: [UInt8] = [2]
        let marker = AXTextMarkerRangeCreateWithBytes(nil, start, start.count, end, end.count)
        for length: Int? in [0, 3, nil] {
            let reader = SelectionReader(parameterizedAttribute: { _, name, _ in
                name == "AXLengthForTextMarkerRange" ? length.map(NSNumber.init(value:)) : nil
            }, attribute: { _, name in
                switch name {
                case kAXRoleAttribute: return "AXWebArea" as CFString
                case "AXSelectedTextMarkerRange": return marker
                default: return nil
                }
            })
            let focused = AXUIElementCreateSystemWide()
            do {
                let result = try await reader.readSelection(focused: focused, applicationPID: nil, copyMenuState: {
                    length == 3 ? .disabled : .unknown
                }) { mode, _ in
                    XCTAssertNotEqual(length, 0)
                    XCTAssertEqual(mode, length == 3 ? .confirmedSelection : .unknownSelection)
                    return "Copied text"
                }
                XCTAssertNotEqual(length, 0)
                XCTAssertEqual(result.text, "Copied text")
            } catch {
                XCTAssertEqual(length, 0)
                XCTAssertEqual(error as? SelectionReadError, .noSelection)
            }
        }
    }

    func testMarkerDirectReadContinuesAfterNativeValueCannotBeSliced() async throws {
        var caret = CFRange(location: 1, length: 0)
        let nativeRange = try XCTUnwrap(AXValueCreate(.cfRange, &caret))
        let start: [UInt8] = [1]
        let end: [UInt8] = [2]
        let marker = AXTextMarkerRangeCreateWithBytes(nil, start, start.count, end, end.count)
        let reader = SelectionReader(parameterizedAttribute: { _, name, _ in
            name == "AXStringForTextMarkerRange" ? "Selected through marker" as CFString : nil
        }, attribute: { _, name in
            switch name {
            case kAXRoleAttribute: return "AXWebArea" as CFString
            case kAXSelectedTextRangeAttribute: return nativeRange
            case kAXValueAttribute: return "Document" as CFString
            case "AXSelectedTextMarkerRange": return marker
            default: return nil
            }
        })
        let result = try await reader.readSelection(focused: AXUIElementCreateSystemWide(), applicationPID: nil) { _, _ in
            XCTFail("The marker should supply text before copy")
            return ""
        }
        XCTAssertEqual(result.text, "Selected through marker")
    }

    func testWindowTextIsNotTheFocusedDocumentSelection() async throws {
        let focused = AXUIElementCreateSystemWide()
        let window = AXUIElementCreateApplication(1)
        let reader = SelectionReader(attribute: { element, attribute in
            if CFEqual(element, focused) {
                return attribute == kAXParentAttribute ? window : nil
            }
            switch attribute {
            case kAXRoleAttribute: return kAXWindowRole as CFString
            case kAXSelectedTextAttribute: return "Seven" as CFString
            default: return nil
            }
        })
        do {
            _ = try await reader.readSelection(focused: focused, applicationPID: nil, copyMenuState: { .disabled }) { _, _ in
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
        let reader = SelectionReader(attribute: { element, attribute in
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
        })
        do {
            _ = try await reader.readSelection(focused: focused, applicationPID: targetPID, copyMenuState: { .disabled }) { _, _ in
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
        let reader = SelectionReader(attribute: { _, attribute in
            switch attribute {
            case kAXRoleAttribute: return kAXTextAreaRole as CFString
            case kAXSelectedTextRangeAttribute: return caretValue
            case kAXSelectedTextRangesAttribute: return [caretValue, selectionValue] as CFArray
            default: return nil
            }
        })
        let result = try await reader.readSelection(focused: AXUIElementCreateSystemWide(), applicationPID: nil) { _, _ in
            "Another selection"
        }
        XCTAssertEqual(result, SelectedText(text: "Another selection", appKitBounds: nil))
    }

    func testFocusedWebDocumentCanProvideSelectedText() async throws {
        let focused = AXUIElementCreateSystemWide()
        let document = AXUIElementCreateApplication(1)
        let reader = SelectionReader(attribute: { element, attribute in
            if CFEqual(element, focused) {
                return attribute == kAXParentAttribute ? document : nil
            }
            switch attribute {
            case kAXRoleAttribute: return "AXWebArea" as CFString
            case kAXSelectedTextAttribute: return "Seven" as CFString
            default: return nil
            }
        })
        let result = try await reader.readSelection(focused: focused, applicationPID: nil) { _, _ in
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
