import AppKit
import Carbon
import XCTest
@testable import Seven

final class PanelBehaviorTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1_200, height: 800)
    private let panelSize = NSSize(width: 500, height: 400)
    /// 跟随鼠标时允许的区域：左、右、下各留 10，顶部不留。
    private func permitted(_ screen: NSRect) -> NSRect {
        NSRect(x: screen.minX + 10, y: screen.minY + 10, width: screen.width - 20, height: screen.height - 10)
    }

    func testOperationGateRejectsLateResultsAndOnlyFinishesCurrentOperation() {
        var gate = OperationGate()
        let first = gate.begin()
        let second = gate.begin()

        XCTAssertFalse(gate.accepts(first))
        XCTAssertFalse(gate.finish(first))
        XCTAssertTrue(gate.accepts(second))
        XCTAssertTrue(gate.finish(second))
        XCTAssertNil(gate.current)
    }

    func testOperationGateInvalidationRejectsInFlightOperation() {
        var gate = OperationGate()
        let token = gate.begin()

        gate.invalidate()

        XCTAssertFalse(gate.accepts(token))
        XCTAssertFalse(gate.finish(token))
    }

    func testPanelTopLeftCornerSitsAtMouse() {
        let frame = PanelGeometry.frame(
            around: NSPoint(x: 300, y: 700),
            size: panelSize,
            within: screen
        )

        XCTAssertEqual(frame.origin, NSPoint(x: 300, y: 300))
        XCTAssertEqual(NSPoint(x: frame.minX, y: frame.maxY), NSPoint(x: 300, y: 700))
    }

    func testPanelIsPushedBackAtRightAndBottomEdgesInsteadOfFlipping() {
        let frame = PanelGeometry.frame(
            around: NSPoint(x: 1_150, y: 40),
            size: panelSize,
            within: screen
        )

        XCTAssertEqual(frame.origin, NSPoint(x: 690, y: 10))
        XCTAssertTrue(permitted(screen).contains(frame))
    }

    func testPanelMayTouchTopOfVisibleFrame() {
        let frame = PanelGeometry.frame(around: NSPoint(x: 300, y: 800), size: panelSize, within: screen)
        XCTAssertEqual(frame.maxY, 800)
    }

    func testSelectionThatIsNotCoveredKeepsMouseAnchoredFrame() {
        let selection = NSRect(x: 100, y: 700, width: 200, height: 18)
        let anchor = NSPoint(x: 300, y: 695)
        let avoiding = PanelGeometry.frame(around: anchor, size: panelSize, within: screen, avoiding: selection)
        let plain = PanelGeometry.frame(around: anchor, size: panelSize, within: screen)
        XCTAssertEqual(avoiding, plain)
    }

    func testPanelAvoidsSelectionBoundsWhenSpaceExists() {
        let selection = NSRect(x: 330, y: 380, width: 280, height: 36)
        let frame = PanelGeometry.frame(
            around: NSPoint(x: selection.midX, y: selection.midY),
            size: panelSize,
            within: screen,
            avoiding: selection
        )

        XCTAssertTrue(permitted(screen).contains(frame))
        let overlap = frame.intersection(selection.insetBy(dx: -14, dy: -14))
        XCTAssertEqual(overlap.width * overlap.height, 0)
    }

    func testPanelChoosesSmallestOverlapWhenSelectionCannotBeFullyAvoided() {
        let smallScreen = NSRect(x: 0, y: 0, width: 700, height: 500)
        let selection = NSRect(x: 40, y: 230, width: 620, height: 40)
        let frame = PanelGeometry.frame(
            around: NSPoint(x: selection.midX, y: selection.midY),
            size: NSSize(width: 500, height: 400),
            within: smallScreen,
            avoiding: selection
        )
        let preferred = PanelGeometry.frame(
            around: NSPoint(x: selection.midX, y: selection.midY),
            size: NSSize(width: 500, height: 400),
            within: smallScreen
        )

        XCTAssertTrue(permitted(smallScreen).contains(frame))
        XCTAssertLessThanOrEqual(
            frame.intersection(selection).width * frame.intersection(selection).height,
            preferred.intersection(selection).width * preferred.intersection(selection).height
        )
    }

    func testResizingKeepsTopEdgeAndClampsToVisibleScreen() {
        let current = NSRect(x: 650, y: 250, width: 500, height: 400)
        let frame = PanelGeometry.frameKeepingTop(current, height: 620, within: screen)

        XCTAssertEqual(frame.maxY, current.maxY)
        XCTAssertGreaterThanOrEqual(frame.minY, 12)
        XCTAssertLessThanOrEqual(frame.maxX, 1_188)
    }

    func testAutoGrowingEditorHeightPolicyClampsToMinimumAndMaximum() {
        XCTAssertEqual(AutoGrowingTextHeightPolicy.clamped(20), 56)
        XCTAssertEqual(AutoGrowingTextHeightPolicy.clamped(144), 144)
        XCTAssertEqual(AutoGrowingTextHeightPolicy.clamped(480), 180)
        XCTAssertEqual(AutoGrowingTextHeightPolicy.clamped(480, maximum: 300), 300)
        XCTAssertEqual(AutoGrowingTextHeightPolicy.clamped(20, maximum: 300), 56)
    }

    func testTranslationWindowLayoutPreferencesNormalizeAndScaleToScreen() {
        XCTAssertEqual(
            TranslationWindowLayoutPreferences.normalizedInputMaximumHeight(293),
            290
        )
        XCTAssertEqual(
            TranslationWindowLayoutPreferences.normalizedMaximumWindowHeightRatio(0.823),
            0.82,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TranslationWindowLayoutPreferences.maximumPanelHeight(
                screenHeight: 1_000,
                ratio: 0.70
            ),
            700,
            accuracy: 0.0001
        )
    }

    func testRepeatedPlacementWithFractionalMouseKeepsWidth() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 944)
        var size = NSSize(width: 400, height: 300)
        for step in 0..<20 {
            let anchor = NSPoint(x: 300.37 + CGFloat(step) * 7.21, y: 700.63)
            let frame = PanelGeometry.frame(around: anchor, size: size, within: screen)
            XCTAssertEqual(frame.width, 400, "第 \(step) 次弹出宽度变化")
            XCTAssertEqual(frame.minX, frame.minX.rounded())
            let avoiding = PanelGeometry.frame(
                around: anchor, size: size, within: screen,
                avoiding: NSRect(x: 280.5, y: 690.25, width: 120.5, height: 18.5)
            )
            XCTAssertEqual(avoiding.width, 400)
            size = frame.size
        }
    }

    func testPanelPlacementModeDefaultsToRememberAndPersists() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PanelPlacementMode.stored(in: defaults), .remember)
        PanelPlacementMode.followMouse.save(in: defaults)
        XCTAssertEqual(PanelPlacementMode.stored(in: defaults), .followMouse)
        defaults.set("bogus", forKey: PanelPlacementMode.storageKey)
        XCTAssertEqual(PanelPlacementMode.stored(in: defaults), .remember)
    }

    func testRememberedFrameKeepsLeftAndTopAndAdjustsHeight() {
        let main = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let last = NSRect(x: 700, y: 300, width: 380, height: 500)
        let frame = PanelGeometry.rememberedFrame(last, height: 320, screens: [main], fallback: main)
        XCTAssertEqual(frame.minX, 700)
        XCTAssertEqual(frame.maxY, last.maxY)
        XCTAssertEqual(frame.size, NSSize(width: 380, height: 320))
    }

    func testRememberedFrameStaysOnItsScreenOrMovesBackWhenDisconnected() {
        let main = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let external = NSRect(x: 1512, y: 0, width: 1920, height: 1050)
        let last = NSRect(x: 2000, y: 400, width: 400, height: 300)

        let kept = PanelGeometry.rememberedFrame(last, height: 300, screens: [main, external], fallback: main)
        XCTAssertEqual(kept.minX, 2000, "外接屏仍在时留在原处")

        let moved = PanelGeometry.rememberedFrame(last, height: 300, screens: [main], fallback: main)
        XCTAssertTrue(main.contains(moved), "外接屏断开后移回当前屏幕内")
        XCTAssertEqual(moved.width, 400)
    }

    func testKeyboardRoutingMatchesWindowContract() {
        XCTAssertEqual(
            PanelKeyboardRouter.action(keyCode: UInt16(kVK_Return), modifiers: [], isEditingText: true),
            .translate
        )
        XCTAssertEqual(
            PanelKeyboardRouter.action(keyCode: UInt16(kVK_Return), modifiers: .command, isEditingText: true),
            .insertNewline
        )
        XCTAssertEqual(
            PanelKeyboardRouter.action(keyCode: UInt16(kVK_Return), modifiers: .shift, isEditingText: true),
            .insertNewline
        )
        XCTAssertEqual(
            PanelKeyboardRouter.action(keyCode: UInt16(kVK_ANSI_R), modifiers: .command, isEditingText: false),
            .retry
        )
        XCTAssertEqual(
            PanelKeyboardRouter.action(keyCode: UInt16(kVK_ANSI_P), modifiers: .command, isEditingText: false),
            .togglePin
        )
        XCTAssertEqual(
            PanelKeyboardRouter.action(
                keyCode: UInt16(kVK_ANSI_P),
                modifiers: [.command, .capsLock, .function],
                isEditingText: false
            ),
            .togglePin
        )
        XCTAssertEqual(
            PanelKeyboardRouter.action(keyCode: UInt16(kVK_Escape), modifiers: [], isEditingText: false),
            .close
        )
    }

    func testKeyboardRoutingLetsInputMethodCommitMarkedText() {
        XCTAssertNil(
            PanelKeyboardRouter.action(
                keyCode: UInt16(kVK_Return),
                modifiers: [],
                isEditingText: true,
                hasMarkedText: true
            )
        )
        XCTAssertNil(
            PanelKeyboardRouter.action(
                keyCode: UInt16(kVK_Return),
                modifiers: .shift,
                isEditingText: true,
                hasMarkedText: true
            )
        )
        XCTAssertNil(
            PanelKeyboardRouter.action(
                keyCode: UInt16(kVK_Escape),
                modifiers: [],
                isEditingText: true,
                hasMarkedText: true
            )
        )
    }

    func testIdleServiceResultNeverExpandsAResultBody() {
        XCTAssertFalse(ServiceResultPresentationPolicy.visibleExpanded(
            persistedExpanded: true,
            phase: .idle
        ))
        XCTAssertFalse(ServiceResultPresentationPolicy.showsBody(
            visibleExpanded: true,
            hasCurrentResult: true,
            clearTransitionActive: false,
            phase: .idle
        ))
        XCTAssertTrue(ServiceResultPresentationPolicy.showsBody(
            visibleExpanded: true,
            hasCurrentResult: true,
            clearTransitionActive: false,
            phase: .skipped
        ))
    }

    func testManualPanelResizeChangesWidthOnly() {
        XCTAssertEqual(
            PanelManualResizePolicy.widthOnly(
                proposed: NSSize(width: 720, height: 900),
                current: NSSize(width: 570, height: 440)
            ),
            NSSize(width: 720, height: 440)
        )
    }

    func testUnpinnedPanelHidesOnOutsideClickEvenWhileARequestCouldBeRunning() {
        XCTAssertTrue(PanelVisibilityPolicy.shouldHide(
            isKeyWindow: false,
            isPinned: false,
            hasAttachedSheet: false
        ))
        XCTAssertFalse(PanelVisibilityPolicy.shouldHide(
            isKeyWindow: false,
            isPinned: false,
            hasAttachedSheet: true
        ))
        XCTAssertFalse(PanelVisibilityPolicy.shouldHide(
            isKeyWindow: false,
            isPinned: false,
            hasAttachedSheet: false,
            hasAnotherApplicationWindow: true
        ))
    }

}

@MainActor
extension PanelBehaviorTests {
    private func panelModel() throws -> TranslationModel {
        _ = NSApplication.shared
        let defaults = try XCTUnwrap(isolatedDefaults())
        let settings = SettingsStore(defaults: defaults)
        settings.serviceInstances = [ServiceInstance(provider: .google)]
        return TranslationModel(credentials: PanelTestCredentials(), settings: settings)
    }

    func testModelRefreshPreservesInputMethodComposition() throws {
        let model = try panelModel()
        defer { model.cancel() }
        model.input = "原文"
        let input = AppKitTranslationInputView(model: model)
        _ = input.applyModel(animated: false)
        let scroll = try XCTUnwrap(input.subviews.compactMap { $0 as? NSScrollView }.first)
        let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
        let automaticRange = NSRange(location: NSNotFound, length: 0)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.setMarkedText("ceshi", selectedRange: NSRange(location: 5, length: 0), replacementRange: automaticRange)
        XCTAssertTrue(editor.hasMarkedText())
        let markedRange = editor.markedRange()
        let markedText = editor.string

        _ = input.applyModel(animated: false)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.markedRange(), markedRange)
        XCTAssertEqual(editor.string, markedText)
        XCTAssertEqual(model.input, "原文")

        editor.insertText("测试", replacementRange: automaticRange)
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(model.input, "原文测试")
    }

    func testStreamingTextRevealsUnicodeInOrderWithoutSplittingCharacters() async {
        let view = StreamingResultTextView()
        let text = String(repeating: "译文👩‍💻é", count: 3)
        let finished = expectation(description: "all characters revealed")
        var revealedCounts: [Int] = []
        view.onVisibleTextChange = { [weak view] in
            guard let view else { return }
            let count = view.string.count
            XCTAssertEqual(Array(view.string.utf16), Array(text.prefix(count).utf16))
            revealedCounts.append(count)
            if view.string == text { finished.fulfill() }
        }
        view.append(NSAttributedString(string: text), progressively: true)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(view.string, text)
        XCTAssertFalse(view.isRevealing)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertTrue(revealedCounts.contains { $0 > 0 && $0 < text.count })
        }
    }

    func testStreamCompletionAndReopeningPreserveBufferedSuffix() async throws {
        let body = AppKitServiceBodyView(model: try panelModel())
        let text = try XCTUnwrap(body.subviews.compactMap { $0 as? StreamingResultTextView }.first)
        let combined = "Prefix é 👩‍💻"
        let complete = combined + "\n第二行"
        var result = panelResult(text: "Prefix e", phase: .streaming)
        body.apply(result)
        result.text = combined
        body.apply(result)
        body.renderingSuspended = true
        let before = text.string
        body.renderingSuspended = false
        result.phase = .success
        result.text = complete
        let finished = expectation(description: "buffered suffix revealed")
        body.onVisibleTextChange = { [weak text] in
            if text?.string == complete { finished.fulfill() }
        }
        body.apply(result)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertTrue(body.isRevealing)
            XCTAssertEqual(text.string, before)
        }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(Array(text.string.utf16), Array(complete.utf16))
        XCTAssertFalse(body.isRevealing)
    }

    func testOnlyUserScrollToBottomEnablesFollowAndReadingEarlierPausesIt() async throws {
        let model = try panelModel()
        model.input = "Source"
        var result = panelResult(text: String(repeating: "Line.\n", count: 90), phase: .success)
        model.serviceResults = [result]
        let controller = AppKitTranslationViewController(model: model)
        controller.view.frame = CGRect(x: 0, y: 0, width: 570, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        controller.refreshWindowLayout(animated: false)
        defer { model.cancel() }
        let scroll = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UserActivityScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        let followLabel = L10n.text("followLatestTranslation")
        let pauseLabel = L10n.text("stopFollowingLatestTranslation")
        let follow = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == followLabel })
        func bottom() -> CGFloat { document.frame.height - scroll.contentSize.height }
        func scrollTo(_ offset: CGFloat) {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        result.phase = .streaming
        model.serviceResults = [result]
        model.isLoading = true
        try await waitForPanelLayout(controller, "开始流式输出") { !follow.isHidden && bottom() > 100 }
        scrollTo(bottom())
        XCTAssertEqual(follow.accessibilityLabel(), followLabel)

        scroll.beginUserIndicatorActivity()
        scrollTo(bottom())
        scroll.endUserIndicatorActivity()
        XCTAssertEqual(follow.accessibilityLabel(), pauseLabel)
        let beforeAppend = bottom()
        result.text += "Next.\nNext.\n"
        model.serviceResults = [result]
        try await waitForPanelLayout(controller, "跟随期间追加内容") { bottom() > beforeAppend + 1 }
        XCTAssertEqual(scroll.contentView.bounds.minY, bottom(), accuracy: 1)

        scroll.beginUserIndicatorActivity()
        scrollTo(20)
        scroll.endUserIndicatorActivity()
        XCTAssertEqual(follow.accessibilityLabel(), followLabel)
        let beforePausedAppend = bottom()
        result.text += "More.\nMore.\n"
        model.serviceResults = [result]
        try await waitForPanelLayout(controller, "暂停跟随后追加内容") { bottom() > beforePausedAppend + 1 }
        XCTAssertEqual(scroll.contentView.bounds.minY, 20, accuracy: 1)
    }

    private func waitForPanelLayout(_ controller: NSViewController, _ step: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            controller.view.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        } while ContinuousClock.now < deadline
        XCTFail("翻译面板没有更新到预期的滚动范围（\(step)）")
    }

    private func panelResult(text: String, phase: TranslationResultPhase) -> TranslationServiceResult {
        TranslationServiceResult(id: .google, title: "Google", subtitle: "", isTranslation: true,
            phase: phase, text: text, dictionaryEntry: nil, errorMessage: nil, elapsed: nil)
    }
}

private struct PanelTestCredentials: CredentialStoring {
    func read(account: String) throws -> String { "" }
    func save(_ value: String, account: String) throws { XCTFail("面板测试不应写入凭据") }
}
