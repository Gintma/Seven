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
        let minimum = AutoGrowingTextHeightPolicy.minimum
        let maximum = minimum + 200
        XCTAssertEqual(AutoGrowingTextHeightPolicy.clamped(minimum - 1, maximum: maximum), minimum)
        XCTAssertEqual(AutoGrowingTextHeightPolicy.clamped(minimum + 1, maximum: maximum), minimum + 1)
        XCTAssertEqual(AutoGrowingTextHeightPolicy.clamped(maximum + 1, maximum: maximum), maximum)
    }

    func testTranslationWindowLayoutPreferencesNormalizeAndScaleToScreen() {
        let height = TranslationWindowLayoutPreferences.normalizedInputMaximumHeight(293)
        let ratio = TranslationWindowLayoutPreferences.normalizedMaximumWindowHeightRatio(0.823)
        XCTAssertGreaterThanOrEqual(height, TranslationWindowLayoutPreferences.minimumInputMaximumHeight)
        XCTAssertLessThanOrEqual(height, TranslationWindowLayoutPreferences.maximumInputMaximumHeight)
        XCTAssertGreaterThanOrEqual(ratio, TranslationWindowLayoutPreferences.minimumWindowHeightRatio)
        XCTAssertLessThanOrEqual(ratio, TranslationWindowLayoutPreferences.maximumWindowHeightRatio)
        XCTAssertEqual(TranslationWindowLayoutPreferences.normalizedInputMaximumHeight(height), height)
        XCTAssertEqual(TranslationWindowLayoutPreferences.normalizedMaximumWindowHeightRatio(ratio), ratio, accuracy: 0.0001)
        let maximumHeight = TranslationWindowLayoutPreferences.maximumInputMaximumHeight
        let minimumRatio = TranslationWindowLayoutPreferences.minimumWindowHeightRatio
        XCTAssertEqual(TranslationWindowLayoutPreferences.normalizedInputMaximumHeight(maximumHeight + 50), maximumHeight)
        XCTAssertEqual(TranslationWindowLayoutPreferences.normalizedMaximumWindowHeightRatio(minimumRatio / 2),
                       minimumRatio, accuracy: 0.0001)
        XCTAssertEqual(TranslationWindowLayoutPreferences.maximumPanelHeight(screenHeight: 1_000, ratio: ratio),
                       1_000 * ratio, accuracy: 0.0001)
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

    func testPanelPlacementModePersistsAndInvalidStorageUsesFallback() throws {
        let suite = "SevenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(isolatedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fallback = PanelPlacementMode.stored(in: defaults)
        let alternate = try XCTUnwrap(PanelPlacementMode.allCases.first { $0 != fallback })
        alternate.save(in: defaults)
        XCTAssertEqual(PanelPlacementMode.stored(in: defaults), alternate)
        defaults.set("bogus", forKey: PanelPlacementMode.storageKey)
        XCTAssertEqual(PanelPlacementMode.stored(in: defaults), fallback)
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
        settings.languageDetectionMode = .system
        settings.serviceInstances = [ServiceInstance(provider: .google)]
        return TranslationModel(credentials: PanelTestCredentials(), settings: settings)
    }

    func testCaptureFailureDoesNotOfferRetryForPreviousInput() throws {
        let model = try panelModel()
        defer { model.cancel() }
        model.input = "Previous source"
        let issueView = AppKitGlobalIssueView(model: model)
        func visibleRetry(in view: NSView) -> Bool {
            guard !view.isHidden else { return false }
            if let button = view as? NSButton, button.title == L10n.text("retry") {
                return true
            }
            return view.subviews.contains(where: visibleRetry(in:))
        }

        model.presentSelectionError(.copyTimedOut)
        issueView.applyModel()
        XCTAssertFalse(issueView.isHidden)
        XCTAssertFalse(visibleRetry(in: issueView))

        model.presentScreenshotError(.noText)
        issueView.applyModel()
        XCTAssertFalse(issueView.isHidden)
        XCTAssertFalse(visibleRetry(in: issueView))
        XCTAssertEqual(model.input, "Previous source")
    }

    func testIssueHeightOnlyWrapsWhenTheMessageExceedsAvailableWidth() throws {
        let model = try panelModel()
        let issueView = AppKitGlobalIssueView(model: model)
        issueView.frame.size.width = TranslationPanelSize.minimumWidth
        model.issue = .verbatim("Unavailable.")
        issueView.applyModel()
        let singleLineHeight = issueView.preferredHeight

        model.issue = .verbatim("The target application did not return any text.")
        issueView.applyModel()
        XCTAssertEqual(issueView.preferredHeight, singleLineHeight, "Space without actions is available for the message")

        model.issue = .verbatim(String(repeating: "The target application did not return any text. ", count: 4))
        issueView.applyModel()
        XCTAssertGreaterThan(issueView.preferredHeight, singleLineHeight)
    }

    func testFirstIssueInVisiblePanelMeasuresAtAvailableContentWidth() throws {
        let model = try panelModel()
        let panel = TranslationPanel(model: model)
        let host = NSView()
        panel.contentView = host
        panel.orderFront(nil)
        defer { panel.orderOut(nil); model.cancel() }

        let issue = AppKitGlobalIssueView(model: model)
        host.addSubview(issue)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(issue.bounds.width, 0)
        XCTAssertTrue(issue.isHidden)
        model.issue = .verbatim(String(repeating: "The target application did not provide the selected text. ", count: 4))
        let reference = AppKitGlobalIssueView(model: model)
        reference.frame.size.width = host.bounds.width
        reference.applyModel()
        XCTAssertGreaterThan(reference.preferredHeight, 40)

        issue.applyModel(availableWidth: host.bounds.width)

        XCTAssertFalse(issue.isHidden)
        XCTAssertEqual(issue.preferredHeight, reference.preferredHeight, accuracy: 0.5)
    }

    func testIssueHeightUsesNewWidthAfterPanelAnimation() async throws {
        let model = try panelModel()
        let panel = TranslationPanel(model: model)
        let controller = AppKitTranslationViewController(model: model)
        panel.contentViewController = controller
        panel.setContentSize(NSSize(width: 560, height: 350))
        panel.orderFront(nil)
        defer { panel.orderOut(nil); model.cancel() }
        controller.view.layoutSubtreeIfNeeded()
        controller.reloadFromModel(animated: false)

        let scroll = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
        let stack = try XCTUnwrap(scroll.documentView?.subviews.compactMap { $0 as? NSStackView }.first)
        let issue = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? AppKitGlobalIssueView }.first)
        let originalWidth = stack.bounds.width
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(issue.isHidden)
        model.issue = .verbatim(String(repeating: "The target application did not provide the selected text. ", count: 6))
        let widthChanged = expectation(description: "width changes during the layout transaction")
        let animationFinished = expectation(description: "issue animation finishes")
        controller.onPreferredPanelHeightChange = { _ in
            controller.onPreferredPanelHeightChange = nil
            var frame = panel.frame
            frame.size.width = TranslationPanelSize.minimumWidth
            panel.setFrame(frame, display: false)
            widthChanged.fulfill()
        }
        controller.reloadFromModel(animated: true) { animationFinished.fulfill() }
        await fulfillment(of: [widthChanged, animationFinished], timeout: 2)

        XCTAssertLessThan(stack.bounds.width, originalWidth)
        let reference = AppKitGlobalIssueView(model: model)
        reference.frame.size.width = stack.bounds.width
        reference.applyModel()
        XCTAssertEqual(issue.preferredHeight, reference.preferredHeight, accuracy: 0.5)
        XCTAssertEqual(issue.renderedHeight, reference.preferredHeight, accuracy: 0.5)
    }

    func testServiceIssueFitsBothActionsAtMinimumWidth() throws {
        try L10n.$languageOverride.withValue(.spanish) {
            let model = try panelModel()
            defer { model.cancel() }
            for service in model.serviceInstances { model.setServiceEnabled(service.id, enabled: false) }
            model.updateInput("Source")
            model.translate()

            let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
            let issueView = AppKitGlobalIssueView(model: model)
            host.addSubview(issueView)
            NSLayoutConstraint.activate([
                issueView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                issueView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                issueView.topAnchor.constraint(equalTo: host.topAnchor)
            ])
            host.layoutSubtreeIfNeeded()

            let message = try XCTUnwrap(issueView.subviews.compactMap { $0 as? NSTextField }.first)
            let actions = try XCTUnwrap(issueView.subviews.compactMap { $0 as? NSStackView }.first)
            let buttons = actions.arrangedSubviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            XCTAssertEqual(Set(buttons.map(\.title)), [L10n.text("retry"), L10n.text("serviceSettings")])
            for button in buttons {
                let frame = issueView.convert(button.bounds, from: button)
                XCTAssertLessThanOrEqual(message.frame.maxX, frame.minX)
                XCTAssertTrue(issueView.bounds.contains(frame))
            }
            XCTAssertTrue(issueView.bounds.contains(message.frame))

            var openedSettings = false
            model.onOpenSettings = { openedSettings = true }
            try XCTUnwrap(buttons.first { $0.title == L10n.text("serviceSettings") }).performClick(nil)
            XCTAssertTrue(openedSettings)
        }
    }

    func testDismissAndCloseClearSessionButKeepLanguageChoices() throws {
        let model = try panelModel()
        let panel = TranslationPanel(model: model)
        defer { panel.orderOut(nil); model.cancel() }
        model.clearTranslationOnDismiss = true
        model.source = "en"
        model.target = "ja"

        panel.orderFront(nil)
        XCTAssertTrue(panel.isVisible)
        model.prepareSelectedText("Previous input")
        model.serviceResults = [panelResult(text: "Previous result", phase: .success)]
        model.issue = SelectionReadError.noSelection.issue
        panel.dismiss()
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(model.input, "")
        XCTAssertTrue(model.serviceResults.isEmpty)
        XCTAssertNil(model.issue)

        panel.orderFront(nil)
        model.pinned = true
        model.presentScreenshotError(.noText)
        panel.performClose(nil)
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(model.issue, "Closing also clears an issue shown with an empty input")
        XCTAssertEqual(model.source, "en")
        XCTAssertEqual(model.target, "ja")
    }

    func testEnablingWhileHiddenClearsOnNextInputPresentation() throws {
        let model = try panelModel()
        let panel = TranslationPanel(model: model)
        defer { panel.orderOut(nil); model.cancel() }
        model.prepareSelectedText("Previous input")
        model.serviceResults = [panelResult(text: "Previous result", phase: .success)]
        panel.orderFront(nil)
        panel.dismiss()

        XCTAssertEqual(model.input, "Previous input")
        XCTAssertEqual(model.serviceResults.first?.text, "Previous result")
        model.clearTranslationOnDismiss = true
        let reopenedModel = TranslationModel(credentials: PanelTestCredentials(), settings: model.settings)
        XCTAssertTrue(reopenedModel.clearTranslationOnDismiss)

        panel.prepareForInputPresentation()
        XCTAssertEqual(model.input, "")
        XCTAssertTrue(model.serviceResults.isEmpty)
    }

    func testRelocationAndContentPresentationsPreserveTextWithClearingEnabled() throws {
        let model = try panelModel()
        let panel = TranslationPanel(model: model)
        defer { panel.orderOut(nil); model.cancel() }
        model.clearTranslationOnDismiss = true

        model.prepareSelectedText("Selected text")
        panel.orderFront(nil)
        panel.prepareForInputPresentation()
        panel.orderOut(nil)
        panel.orderFront(nil)
        XCTAssertEqual(model.input, "Selected text")

        panel.dismiss()
        model.prepareScreenshotText("Text from a screenshot", needsReview: true)
        panel.orderFront(nil)
        XCTAssertEqual(model.input, "Text from a screenshot")
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

    func testMarkdownBodyPausesWhenFoldedAndReopensWithTheLatestSnapshot() async throws {
        let model = try panelModel()
        let body = AppKitServiceBodyView(model: model)
        let view = try XCTUnwrap(body.subviews.compactMap { $0 as? StreamingResultTextView }.first)
        var result = markdownPanelResult(id: model.addService(.custom), text: "**Initial**", phase: .streaming)
        func publish(_ result: TranslationServiceResult) {
            model.serviceResults = [result]
            body.apply(result)
        }
        publish(result)
        try await waitForMarkdownBody { view.string == "Initial" }
        result.text = "**Intermediate**"
        publish(result)
        body.renderingSuspended = true
        result.text = "**Latest** [Label](https://example.com)"
        result.markdownOutput?.status = .completed
        result.phase = .success
        publish(result)
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertEqual(view.string, "Initial")

        body.renderingSuspended = false
        publish(result)
        try await waitForMarkdownBody { view.string == "Latest Label" }
        XCTAssertEqual(body.speechText(for: result), "Latest Label")
        XCTAssertTrue(view.copiesSelectionAsPlainText)
        model.rendersCustomResultsAsMarkdown = false
        publish(result)
        XCTAssertEqual(view.string, result.text)
        XCTAssertEqual(body.speechText(for: result), result.text)
        XCTAssertFalse(view.copiesSelectionAsPlainText)

        model.rendersCustomResultsAsMarkdown = true
        publish(result)
        try await waitForMarkdownBody { view.string == "Latest Label" }
        XCTAssertEqual(body.speechText(for: result), "Latest Label")
    }

    func testDisablingMarkdownCancelsPendingParsingAndReadsLatestLiteralResult() async throws {
        let model = try panelModel()
        let body = AppKitServiceBodyView(model: model)
        var result = markdownPanelResult(id: model.addService(.custom), text: "**Pending**", phase: .streaming)
        func publish() {
            model.serviceResults = [result]
            body.apply(result)
        }

        let disabledParse = expectation(description: "Markdown parsing must not deliver after disabling the setting")
        disabledParse.isInverted = true
        body.onMarkdownSpeechChange = { disabledParse.fulfill() }
        publish()
        XCTAssertEqual(body.speechText(for: result), "")

        model.rendersCustomResultsAsMarkdown = false
        publish()
        result.text = "Latest [label](https://example.com)\n\n```text\ncode\n```"
        result.markdownOutput?.status = .completed
        result.phase = .success
        publish()
        XCTAssertEqual(body.speechText(for: result), result.text)
        await fulfillment(of: [disabledParse], timeout: 0.4)
        XCTAssertEqual(body.speechText(for: result), result.text)

        let enabledParse = expectation(description: "Reenabling Markdown parses the latest result")
        body.onMarkdownSpeechChange = { enabledParse.fulfill() }
        model.rendersCustomResultsAsMarkdown = true
        publish()
        await fulfillment(of: [enabledParse], timeout: 2)
        XCTAssertEqual(body.speechText(for: result), "Latest label")
    }

    func testMarkdownWideTableHasIndependentHorizontalScrollAndCopiesAcrossTheTable() async throws {
        let model = try panelModel()
        let body = AppKitServiceBodyView(model: model)
        body.frame.size = NSSize(width: 320, height: 400)
        let view = try XCTUnwrap(body.subviews.compactMap { $0 as? StreamingResultTextView }.first)
        let raw = """
            Before

            | A | B | C | D | E | F |
            | --- | --- | --- | --- | --- | --- |
            | One | AlphaBetaGammaDelta | 三 | 四 | 五 | LastCell |

            After
            """
        let result = markdownPanelResult(id: model.addService(.custom), text: raw, phase: .success)
        model.serviceResults = [result]
        body.apply(result)
        try await waitForMarkdownBody { view.string.contains("After") }
        body.layoutSubtreeIfNeeded()

        let table = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(table.documentView)
        let cellPoint = table.convert(NSPoint(x: 24, y: 24), to: body)
        let hit = try XCTUnwrap(view.hitTest(cellPoint))
        XCTAssertTrue(hit.isDescendant(of: table), "The result text view must route pointer input into table cells")
        XCTAssertTrue(table.hasHorizontalScroller)
        XCTAssertFalse(table.hasVerticalScroller)
        XCTAssertGreaterThan(document.frame.width, table.contentSize.width)
        let end = document.frame.width - table.contentSize.width
        table.contentView.scroll(to: NSPoint(x: end, y: 0))
        table.reflectScrolledClipView(table.contentView)
        XCTAssertEqual(table.contentView.bounds.minX, end, accuracy: 1)
        XCTAssertEqual(table.contentView.bounds.minY, 0, accuracy: 1)
        let offset = table.contentView.bounds.minX
        if let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                wheel1: 0, wheel2: 60, wheel3: 0),
           let event = NSEvent(cgEvent: scroll) {
            hit.scrollWheel(with: event)
            XCTAssertLessThan(table.contentView.bounds.minX, offset)
        } else {
            XCTFail("Could not construct horizontal scroll event")
        }

        let pasteboard = NSPasteboard(name: .init("SevenTests.WideTable.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        XCTAssertTrue(view.copyPlainSelection(to: pasteboard))
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(copied.hasPrefix("Before"))
        XCTAssertTrue(copied.contains("AlphaBetaGammaDelta"))
        XCTAssertTrue(copied.contains("LastCell"))
        XCTAssertTrue(copied.hasSuffix("After"))
        XCTAssertFalse(copied.contains("\u{FFFC}"))
        let innerText = try XCTUnwrap(document as? StreamingResultTextView)
        innerText.setSelectedRange((innerText.string as NSString).range(of: "LastCell"))
        XCTAssertTrue(innerText.copyPlainSelection(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "LastCell")

        body.frame.size.width = 750
        _ = body.measuredHeight(for: 750)
        body.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.subviews.contains { $0 is NSScrollView })
        XCTAssertTrue(view.string.contains("LastCell"))
    }

    func testMarkdownBodyHeightStopsAtTheFinalTableBorder() async throws {
        let model = try panelModel()
        let body = AppKitServiceBodyView(model: model)
        let view = try XCTUnwrap(body.subviews.compactMap { $0 as? StreamingResultTextView }.first)
        let raw = "| 车次 | 状态 |\n| --- | --- |\n| G101 | 准点 |"
        let result = markdownPanelResult(id: model.addService(.custom), text: raw, phase: .success)
        model.serviceResults = [result]
        body.apply(result)
        try await waitForMarkdownBody { view.string.hasPrefix("车次") }
        let height = body.measuredHeight(for: 304)
        let manager = try XCTUnwrap(view.layoutManager)
        let location = (view.string as NSString).range(of: "准点").location
        let style = try XCTUnwrap(view.textStorage?.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
        let cell = try XCTUnwrap(style.textBlocks.last as? NSTextTableBlock)
        let cellBounds = manager.boundsRect(for: cell, at: manager.glyphIndexForCharacter(at: location), effectiveRange: nil)
        XCTAssertEqual(height, ceil(cellBounds.maxY), accuracy: 1)
    }

    func testOversizeMarkdownResultShowsFullLiteralSourceIncrementally() async throws {
        let model = try panelModel()
        let body = AppKitServiceBodyView(model: model)
        let view = try XCTUnwrap(body.subviews.compactMap { $0 as? StreamingResultTextView }.first)
        let raw = "**Header**\n" + String(repeating: "👩‍💻 e\u{301}\n", count: 4600) + "Tail"
        let result = markdownPanelResult(id: model.addService(.custom), text: raw, phase: .success)
        model.serviceResults = [result]
        var intermediate = false
        body.onVisibleTextChange = { [weak view] in
            guard let view, !view.string.isEmpty, view.string != raw else { return }
            intermediate = true
            XCTAssertTrue(raw.hasPrefix(view.string))
        }
        body.apply(result)
        try await waitForMarkdownBody { view.string == raw }
        XCTAssertTrue(intermediate)
        XCTAssertEqual(view.string, raw)
        XCTAssertFalse(view.isRevealing)
        XCTAssertTrue(body.speechText(for: result) == raw, "朗读降级结果时使用完整的纯文本")
    }

    func testMarkdownRestyleKeepsReadingLineAtViewportEdge() async throws {
        let model = try panelModel()
        model.input = "Source"
        model.rendersCustomResultsAsMarkdown = false
        let raw = (0..<60).map { "# Heading number \($0)\n\nBody number \($0)\n\n" }.joined()
        let result = markdownPanelResult(id: model.addService(.custom), text: raw, phase: .success)
        model.serviceResults = [result]
        let controller = AppKitTranslationViewController(model: model)
        controller.view.frame = CGRect(x: 0, y: 0, width: 570, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        controller.refreshWindowLayout(animated: false)
        let scroll = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UserActivityScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        func resultTextView(in view: NSView) -> StreamingResultTextView? {
            if let textView = view as? StreamingResultTextView { return textView }
            return view.subviews.lazy.compactMap { resultTextView(in: $0) }.first
        }
        let view = try XCTUnwrap(resultTextView(in: document))
        func topOfLine(_ title: String) -> CGFloat? {
            let range = (view.string as NSString).range(of: title)
            guard range.location != NSNotFound,
                  let manager = view.layoutManager, let container = view.textContainer else { return nil }
            manager.ensureLayout(for: container)
            let glyph = manager.glyphIndexForCharacter(at: range.location)
            let bounds = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return document.convert(NSPoint(x: 0, y: view.textContainerOrigin.y + bounds.minY), from: view).y
        }
        let line = "Heading number 21"
        let initial = try XCTUnwrap(topOfLine(line))
        scroll.beginUserIndicatorActivity()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: initial + 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.endUserIndicatorActivity()
        XCTAssertEqual(scroll.contentView.bounds.minY, initial + 2, accuracy: 1)

        model.rendersCustomResultsAsMarkdown = true
        try await waitForPanelLayout(controller, "Markdown 保留阅读行") {
            guard view.string.hasPrefix("Heading number 0"), let updated = topOfLine(line) else { return false }
            return abs(scroll.contentView.bounds.minY - updated - 2) < 2
        }
        let moved = try XCTUnwrap(topOfLine(line))
        XCTAssertNotEqual(moved, initial)
        XCTAssertEqual(scroll.contentView.bounds.minY, moved + 2, accuracy: 2)
    }

    private func markdownPanelResult(id: TranslationProviderID, text: String, phase: TranslationResultPhase) -> TranslationServiceResult {
        var result = TranslationServiceResult(id: id, title: "Fixture", subtitle: "", isTranslation: true,
            phase: phase, text: text, dictionaryEntry: nil, errorMessage: nil)
        var output = MarkdownOutput()
        if phase == .success { output.status = .completed }
        result.markdownOutput = output
        return result
    }

    private func waitForMarkdownBody(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Markdown 正文没有完成更新")
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
            phase: phase, text: text, dictionaryEntry: nil, errorMessage: nil)
    }
}

private struct PanelTestCredentials: CredentialStoring {
    func read(account: String) throws -> String { "" }
    func save(_ value: String, account: String) throws { XCTFail("面板测试不应写入凭据") }
}
