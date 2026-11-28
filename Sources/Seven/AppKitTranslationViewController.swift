import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class AppKitTranslationViewController: NSViewController, ThemeApplying {
    /// Titlebar bottom meets the input field directly: the system centers toolbar icons ~10 pt from the window top,
    /// leaving ~10 pt to the input field as well for equal top and bottom clearance.
    private static let topInset: CGFloat = 0
    /// Bottom margin from the last section to the window edge, matching the side margins.
    private static let bottomInset = Design.Space.l
    private let model: TranslationModel
    private let scrollView = UserActivityScrollView()
    private let documentView = FlippedView()
    private let rootStack = NSStackView()
    private let serviceContainer = FlippedView()
    private let serviceStack = NSStackView()
    private let inputView: AppKitTranslationInputView
    private let languageBar: AppKitLanguageBar
    private let issueView: AppKitGlobalIssueView
    private var serviceContainerHeightConstraint: NSLayoutConstraint!
    private var serviceCards: [TranslationProviderID: AppKitServiceCardView] = [:]
    private var currentProviderOrder: [TranslationProviderID] = []
    private var modelCancellable: AnyCancellable?
    private var speechCancellable: AnyCancellable?
    private var appleBridgeHost: NSView?
    private var reloadWorkItem: DispatchWorkItem?
    private var lastReloadTime: CFTimeInterval = 0
    private var isApplyingModel = false
    private var isCommittingLayout = false
    private var structuralTransactionActive = false
    private var pendingReload = false
    private var pendingIssueHeight: CGFloat?
    private var issueHeightUpdateScheduled = false
    private var lastDocumentWidth: CGFloat = 0
    private let layoutTransition = PanelLayoutTransition()
    private var renderedLayoutWorkItem: DispatchWorkItem?
    private var dirtyProviders = Set<TranslationProviderID>()
    private let followButton = SymbolButton(symbol: "arrow.down.to.line", label: L10n.text("followLatestTranslation"))
    private var followsStreamingOutput = false
    private var markdownReadingAnchor: (() -> CGFloat?)?
    private var previousLoading = false
    private var previousInput = ""

    var onPreferredPanelHeightChange: ((CGFloat) -> Void)?
    private(set) var preferredPanelHeight: CGFloat = 440
    private let followButtonSize: CGFloat = 30

    init(model: TranslationModel) {
        self.model = model
        self.inputView = AppKitTranslationInputView(model: model)
        self.languageBar = AppKitLanguageBar(model: model)
        self.issueView = AppKitGlobalIssueView(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = LayerBackedView()
        root.translatesAutoresizingMaskIntoConstraints = true
        view = root

        OverlayScrollerPolicy.configure(scrollView)
        scrollView.installUserActivityIndicatorPolicy(drawsTrack: false)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)
        followButton.wantsLayer = true
        followButton.layer?.cornerRadius = followButtonSize / 2
        root.onEffectiveAppearanceChange = { [weak self] in
            self?.applyTheme(ThemeManager.shared.palette)
        }
        followButton.target = self
        followButton.action = #selector(toggleStreamingFollow)
        followButton.isHidden = true
        root.addSubview(followButton)
        layoutTransition.onFrame = { [weak self] in self?.commitCurrentLayoutFrame() }
        scrollView.onUserScroll = { [weak self] isAtBottom in
            self?.markdownReadingAnchor = nil
            self?.followsStreamingOutput = isAtBottom
            self?.updateFollowButton()
        }
        NSLayoutConstraint.activate([
            followButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Design.Space.l),
            followButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Design.Space.l),
            followButton.widthAnchor.constraint(equalToConstant: followButtonSize),
            followButton.heightAnchor.constraint(equalToConstant: followButtonSize),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        // Keep document background transparent; the root view paints the background for the current appearance.
        scrollView.documentView = documentView
        documentView.frame = NSRect(x: 0, y: 0, width: TranslationPanelSize.defaultWidth, height: 440)

        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.distribution = .fill
        rootStack.spacing = Design.Space.m
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: TranslationPanelSize.horizontalContentInset),
            rootStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -TranslationPanelSize.horizontalContentInset),
            rootStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: Self.topInset)
        ])

        serviceContainer.translatesAutoresizingMaskIntoConstraints = false
        serviceStack.orientation = .vertical
        serviceStack.alignment = .leading
        serviceStack.distribution = .fill
        serviceStack.spacing = Design.Space.s
        serviceStack.translatesAutoresizingMaskIntoConstraints = false
        serviceContainer.addSubview(serviceStack)
        serviceContainerHeightConstraint = serviceContainer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            serviceContainerHeightConstraint,
            serviceStack.leadingAnchor.constraint(equalTo: serviceContainer.leadingAnchor),
            serviceStack.trailingAnchor.constraint(equalTo: serviceContainer.trailingAnchor),
            serviceStack.topAnchor.constraint(equalTo: serviceContainer.topAnchor)
        ])

        rootStack.addArrangedSubview(inputView)
        rootStack.addArrangedSubview(languageBar)
        rootStack.addArrangedSubview(issueView)
        rootStack.addArrangedSubview(serviceContainer)
        for item in [inputView, languageBar, issueView, serviceContainer] {
            item.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        }

        inputView.onPreferredHeightChange = { [weak self] _, animated in
            self?.componentHeightChanged(animated: animated)
        }
        inputView.onClear = { [weak self] in self?.clearInput() }
        inputView.onEditingLayoutChange = { [weak self] in self?.scheduleReload() }
        issueView.onPreferredHeightChange = { [weak self] height in
            self?.issueHeightChanged(to: height)
        }

        modelCancellable = model.objectWillChange.sink { [weak self] _ in
            self?.scheduleReload()
        }
        speechCancellable = model.speech.objectWillChange.sink { [weak self] _ in
            self?.scheduleReload()
        }

        ThemeManager.shared.register(self)
        installAppleTranslationBridge()
        reloadFromModel(animated: false)
    }

    func applyTheme(_ palette: ThemePalette) {
        guard isViewLoaded, let root = view as? LayerBackedView else { return }
        root.fillColor = palette.surface
        root.window?.backgroundColor = palette.surface
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            followButton.layer?.backgroundColor = palette.surface.cgColor
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyTheme(ThemeManager.shared.palette)
        focusInput()
        if #available(macOS 15.0, *) { model.setSystemTranslationBridgeAvailable(true) }
    }

    func focusInput() {
        inputView.focus()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        model.setSystemTranslationBridgeAvailable(false)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = max(1, scrollView.contentSize.width)
        guard width >= 320 else { return }
        guard abs(width - lastDocumentWidth) > 0.5, !isCommittingLayout else { return }
        lastDocumentWidth = width
        var frame = documentView.frame
        frame.size.width = width
        documentView.frame = frame
        reloadFromModel(animated: false)
    }

    func refreshInterfaceLanguage() {
        inputView.refreshInterfaceLanguage()
        languageBar.refreshInterfaceLanguage()
        issueView.refreshInterfaceLanguage()
        serviceCards.values.forEach { $0.refreshInterfaceLanguage() }
        updateFollowButton()
        scheduleReload()
    }

    func refreshWindowLayout(animated: Bool) {
        performUnifiedLayout(animated: animated)
    }

    private func scheduleReload() {
        guard !structuralTransactionActive else {
            pendingReload = true
            return
        }
        guard reloadWorkItem == nil else { return }
        let now = CACurrentMediaTime()
        let minimumInterval = model.isLoading ? (1.0 / 60.0) : 0
        let delay = max(0, minimumInterval - (now - lastReloadTime))
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reloadWorkItem = nil
            self.lastReloadTime = CACurrentMediaTime()
            self.reloadFromModel(animated: true)
        }
        reloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func reloadFromModel(animated: Bool, completion: (() -> Void)? = nil) {
        guard isViewLoaded, !isApplyingModel else { return }
        isApplyingModel = true
        view.layoutSubtreeIfNeeded()
        let previousHeights = managedHeightConstraints().map { ($0, $0.constant) }
        if model.input != previousInput || (model.isLoading && !previousLoading) {
            followsStreamingOutput = false
            markdownReadingAnchor = nil
        }
        previousInput = model.input
        previousLoading = model.isLoading
        let inputHeightChanged = inputView.applyModel(animated: animated)
        languageBar.applyModel()
        issueView.applyModel(availableWidth: issueContentWidth)

        let results = model.displayedServiceResults
        let order = results.map(\.id)
        let orderChanged = order != currentProviderOrder
        if orderChanged {
            currentProviderOrder = order
            serviceStack.removeAllArrangedSubviews()
            serviceCards = serviceCards.filter { order.contains($0.key) }
            for result in results {
                let card = card(for: result.id)
                serviceStack.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: serviceStack.widthAnchor).isActive = true
            }
        }

        var structuralChange = orderChanged || inputHeightChanged || pendingIssueHeight != nil
        for result in results {
            let update = card(for: result.id).apply(
                result,
                hasCurrentResult: model.hasCurrentResult(result.id),
                suppressBody: structuralTransactionActive,
                animated: animated
            )
            structuralChange = update.structuralChange || structuralChange
        }
        updateServiceContainerHeight()
        isApplyingModel = false

        let shouldAnimate = animated && view.window?.isVisible == true
        performUnifiedLayout(animated: shouldAnimate, previousHeights: previousHeights, targets: takeIssueHeightTarget(),
                             duration: structuralChange ? Design.Motion.standard : Design.Motion.follow, completion: completion)
    }

    private var issueContentWidth: CGFloat {
        let stackWidth = rootStack.bounds.width
        if stackWidth.isFinite, stackWidth > 1 { return stackWidth }
        let documentWidth = documentView.bounds.width - 2 * TranslationPanelSize.horizontalContentInset
        if documentWidth.isFinite, documentWidth > 1 { return documentWidth }
        return TranslationPanelSize.defaultContentWidth
    }

    private func issueHeightChanged(to height: CGFloat) {
        pendingIssueHeight = height
        guard !isApplyingModel, !issueHeightUpdateScheduled else { return }
        issueHeightUpdateScheduled = true
        // Only record measurements before layout frames are committed; replace the interpolated target on the next pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.issueHeightUpdateScheduled = false
            let targets = self.takeIssueHeightTarget()
            guard !targets.isEmpty else { return }
            let animated = self.layoutTransition.isActive && self.view.window?.isVisible == true
            self.performUnifiedLayout(animated: animated, targets: targets, duration: Design.Motion.follow)
        }
    }

    private func takeIssueHeightTarget() -> [(NSLayoutConstraint, CGFloat)] {
        guard let height = pendingIssueHeight else { return [] }
        pendingIssueHeight = nil
        return [(issueView.heightConstraint, height)]
    }

    private func card(for provider: TranslationProviderID) -> AppKitServiceCardView {
        if let card = serviceCards[provider] { return card }
        let card = AppKitServiceCardView(model: model, provider: provider)
        card.onPreferredHeightChange = { [weak self] _, animated in
            self?.componentHeightChanged(animated: animated)
        }
        card.onVisibleTextChange = { [weak self] in self?.renderedContentChanged(provider) }
        card.onMarkdownReflow = { [weak self] in self?.captureMarkdownReadingAnchor() }
        serviceCards[provider] = card
        return card
    }

    private func captureMarkdownReadingAnchor() {
        guard markdownReadingAnchor == nil, !followsStreamingOutput, !isCommittingLayout else { return }
        let y = scrollView.contentView.bounds.minY
        for provider in currentProviderOrder {
            guard let card = serviceCards[provider], card.superview != nil else { continue }
            let rect = documentView.convert(card.bounds, from: card)
            if rect.minY <= y, y < rect.maxY {
                markdownReadingAnchor = card.readingAnchor(at: y, in: documentView)
                return
            }
        }
    }

    private func componentHeightChanged(animated: Bool) {
        guard !isApplyingModel, !isCommittingLayout else { return }
        updateServiceContainerHeight()
        performUnifiedLayout(animated: animated)
    }

    private func updateServiceContainerHeight() {
        let cards = currentProviderOrder.compactMap { serviceCards[$0] }
        let gaps = CGFloat(max(0, cards.count - 1)) * serviceStack.spacing
        serviceContainerHeightConstraint.constant = cards.reduce(gaps) { $0 + $1.preferredHeight }
        serviceContainer.isHidden = cards.isEmpty
    }

    private func renderedContentChanged(_ provider: TranslationProviderID) {
        guard !isApplyingModel, !structuralTransactionActive else { return }
        dirtyProviders.insert(provider)
        guard renderedLayoutWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.renderedLayoutWorkItem = nil
            guard !self.structuralTransactionActive else { self.dirtyProviders.removeAll(); return }
            let previous = self.managedHeightConstraints().map { ($0, $0.constant) }
            self.isApplyingModel = true
            let dirty = self.dirtyProviders
            self.dirtyProviders.removeAll()
            for provider in dirty { self.serviceCards[provider]?.updateVisibleBodyHeight() }
            self.isApplyingModel = false
            if self.markdownReadingAnchor != nil || previous.contains(where: { abs($0.0.constant - $0.1) > 0.01 }) {
                self.performUnifiedLayout(animated: self.view.window?.isVisible == true,
                                          previousHeights: previous, duration: Design.Motion.follow)
            } else {
                self.updateFollowButton()
            }
        }
        renderedLayoutWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func naturalDocumentHeight() -> CGFloat {
        var heights = [inputView.renderedHeight, AppKitLanguageBar.preferredHeight]
        if !issueView.isHidden { heights.append(issueView.renderedHeight) }
        if !serviceContainer.isHidden { heights.append(serviceContainerHeightConstraint.constant) }
        return Self.topInset + heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * rootStack.spacing
            + Self.bottomInset
    }

    private func managedHeightConstraints() -> [NSLayoutConstraint] {
        inputView.layoutHeightConstraints + currentProviderOrder.flatMap { serviceCards[$0]?.layoutHeightConstraints ?? [] }
    }

    private func performUnifiedLayout(
        animated: Bool,
        previousHeights: [(NSLayoutConstraint, CGFloat)] = [],
        targets: [(NSLayoutConstraint, CGFloat)] = [],
        duration: TimeInterval = Design.Motion.standard,
        completion: (() -> Void)? = nil
    ) {
        guard isViewLoaded else { completion?(); return }
        let changes = previousHeights.compactMap { constraint, previous -> (NSLayoutConstraint, CGFloat)? in
            guard abs(constraint.constant - previous) > 0.01 else { return nil }
            let target = constraint.constant
            constraint.constant = previous
            return (constraint, target)
        }
        let seconds = animated && markdownReadingAnchor == nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? duration : 0
        layoutTransition.update(changes: changes + targets, duration: seconds) { [weak self] in
            self?.inputView.finishViewportLayout()
            completion?()
        }
    }

    private func commitCurrentLayoutFrame() {
        guard !isCommittingLayout else { return }
        isCommittingLayout = true
        defer { isCommittingLayout = false }
        let previousOrigin = scrollView.contentView.bounds.origin
        let readingAnchor = markdownReadingAnchor
        markdownReadingAnchor = nil
        let cards = currentProviderOrder.compactMap { serviceCards[$0] }
        serviceContainerHeightConstraint.constant = cards.reduce(
            CGFloat(max(0, cards.count - 1)) * serviceStack.spacing
        ) { $0 + $1.renderedHeight }
        serviceContainer.isHidden = cards.isEmpty
        view.layoutSubtreeIfNeeded()
        let lastView = serviceStack.arrangedSubviews.last
            ?? rootStack.arrangedSubviews.last(where: { !$0.isHidden })
        let naturalHeight = lastView.map { documentView.convert($0.bounds, from: $0).maxY + Self.bottomInset }
            ?? naturalDocumentHeight()
        let titlebarHeight = view.window.map { max(0, $0.frame.height - view.frame.height) }
            ?? TranslationWindowLayoutPreferences.titlebarHeightAllowance
        let maximumWindowHeight = TranslationWindowLayoutPreferences.maximumPanelHeight(
            screenHeight: model.panelScreenHeight, ratio: model.maximumWindowHeightRatio
        )
        let viewportHeight = min(
            max(naturalHeight, TranslationWindowLayoutPreferences.minimumPanelHeight - titlebarHeight),
            max(1, maximumWindowHeight - titlebarHeight)
        )
        preferredPanelHeight = viewportHeight + titlebarHeight
        onPreferredPanelHeightChange?(preferredPanelHeight)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            resizeWindow(to: preferredPanelHeight)
            view.layoutSubtreeIfNeeded()
            documentView.frame = NSRect(
                x: 0, y: 0,
                width: max(320, scrollView.contentSize.width),
                height: max(naturalHeight, scrollView.contentSize.height)
            )
            view.layoutSubtreeIfNeeded()
        }
        if followsStreamingOutput {
            scrollToBottom()
        } else {
            let origin = NSPoint(x: previousOrigin.x, y: min(
                max(0, readingAnchor?() ?? previousOrigin.y), max(0, documentView.frame.height - scrollView.contentSize.height)
            ))
            if scrollView.contentView.bounds.origin != origin {
                scrollView.contentView.scroll(to: origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        updateFollowButton()
    }

    @objc private func toggleStreamingFollow() {
        followsStreamingOutput.toggle()
        if followsStreamingOutput { scrollToBottom() }
        updateFollowButton()
    }

    private func updateFollowButton() {
        followButton.isHidden = documentView.frame.height <= scrollView.contentSize.height + 1
            || !(model.isLoading || currentProviderOrder.contains { serviceCards[$0]?.isRevealing == true })
        followButton.setSymbol(followsStreamingOutput ? "pause.fill" : "arrow.down.to.line", size: 13)
        followButton.toolTip = followsStreamingOutput ? L10n.text("stopFollowingLatestTranslation") : L10n.text("followLatestTranslation")
        followButton.setAccessibilityLabel(followButton.toolTip!)
    }

    private func resizeWindow(to height: CGFloat) {
        guard let window = view.window,
              let screen = window.screen ?? NSScreen.main else { return }
        model.updatePanelScreenHeight(screen.visibleFrame.height)
        let maximum = TranslationWindowLayoutPreferences.maximumPanelHeight(
            screenHeight: screen.visibleFrame.height,
            ratio: model.maximumWindowHeightRatio
        )
        let fitted = min(max(height, TranslationWindowLayoutPreferences.minimumPanelHeight), maximum)
        let target = PanelGeometry.frameKeepingTop(
            window.frame,
            height: fitted,
            within: screen.visibleFrame
        )
        guard abs(target.height - window.frame.height) > 0.5 || target.origin != window.frame.origin else { return }
        window.setFrame(target, display: window.isVisible)
    }

    private func clearInput() {
        guard !model.input.isEmpty, !structuralTransactionActive else { return }
        reloadWorkItem?.cancel()
        reloadWorkItem = nil
        renderedLayoutWorkItem?.cancel()
        renderedLayoutWorkItem = nil
        dirtyProviders.removeAll()
        followsStreamingOutput = false
        markdownReadingAnchor = nil
        structuralTransactionActive = true
        pendingReload = false
        model.beginClearTransition()
        reloadFromModel(animated: true) { [weak self] in
            guard let self else { return }
            self.model.finishClearTransition()
            self.structuralTransactionActive = false
            self.reloadFromModel(animated: false)
            if self.pendingReload {
                self.pendingReload = false
                self.scheduleReload()
            }
            self.inputView.focus()
        }
    }

    private func scrollToBottom() {
        guard documentView.frame.height > scrollView.contentSize.height else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: documentView.frame.height - scrollView.contentSize.height))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func installAppleTranslationBridge() {
        guard #available(macOS 15.0, *) else { return }
        let host = NSHostingView(rootView: AppleTranslationBridgeRoot(model: model))
        host.frame = .zero
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 0),
            host.heightAnchor.constraint(equalToConstant: 0),
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor)
        ])
        appleBridgeHost = host
    }
}
