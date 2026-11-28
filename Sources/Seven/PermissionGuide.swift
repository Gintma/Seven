import AppKit
import CoreGraphics
import Combine
import SwiftUI

@MainActor
final class PermissionGuide {
    enum Permission {
        case accessibility
        case screenRecording

        var title: String {
            switch self {
            case .accessibility: L10n.text("accessibility")
            case .screenRecording: L10n.text("screenRecording")
            }
        }

        var settingsURL: URL? {
            let anchor = switch self {
            case .accessibility: "Privacy_Accessibility"
            case .screenRecording: "Privacy_ScreenCapture"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        }

        var restartHint: String? {
            switch self {
            case .accessibility: nil
            case .screenRecording: L10n.text("reopenSevenAfterEnablingThisPermission")
            }
        }
    }

    static let shared = PermissionGuide(tracker: SettingsWindowTracker(), openPane: {
        await PermissionSettingsNavigator(workspace: SystemPermissionSettings()).open($0)
    }, isGranted: {
        switch $0 {
        case .accessibility: SelectionReader.isAccessibilityTrusted
        case .screenRecording: CGPreflightScreenCaptureAccess()
        }
    })

    private let tracker: any PermissionWindowTracking
    private let openPane: (URL) async -> Bool
    private let isGranted: (Permission) -> Bool
    private var panel: PermissionGuidePanel?
    private var hostingView: NSHostingView<ThemedContent<PermissionGuideView>>?
    private var openingTask: Task<Void, Never>?
    private var activationObserver: AnyCancellable?
    private var permission: Permission?
    private var onGranted: (() -> Void)?
    private weak var owner: AnyObject?
    private var previousApplication: NSRunningApplication?
    private var isWaiting = true
    private var openingFailed = false
    private var panelWidth = Design.PermissionGuide.width
    private var didAttach = false

    init(tracker: any PermissionWindowTracking, openPane: @escaping (URL) async -> Bool,
         isGranted: @escaping (Permission) -> Bool) {
        self.tracker = tracker
        self.openPane = openPane
        self.isGranted = isGranted
        tracker.onFrameChange = { [weak self] frame in
            guard let self else { return }
            let firstFrame = self.isWaiting
            self.isWaiting = false
            self.placePanel(near: frame, animate: firstFrame)
        }
        tracker.onPoll = { [weak self] in self?.refreshPermission() }
        tracker.onSettingsClosed = { [weak self] in self?.close() }
        activationObserver = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.rebuildContent() }
            }
    }

    func refreshPermission() {
        guard let permission, isGranted(permission) else { return }
        let notifyGranted = onGranted
        close()
        notifyGranted?()
    }

    func authorize(
        _ permission: Permission,
        owner: AnyObject? = nil,
        returningTo application: NSRunningApplication? = NSWorkspace.shared.frontmostApplication,
        onGranted: (() -> Void)? = nil
    ) {
        if self.permission == nil {
            previousApplication = application
        }
        close()
        guard !isGranted(permission) else {
            onGranted?()
            return
        }
        self.owner = owner
        self.permission = permission
        self.onGranted = onGranted
        isWaiting = true
        openingFailed = false
        didAttach = false
        panelWidth = Design.PermissionGuide.width
        showPanel()
        openSettings()
    }

    private func openSettings() {
        guard let url = permission?.settingsURL else { return }
        openingTask?.cancel()
        tracker.stop()
        isWaiting = true
        openingFailed = false
        rebuildContent()
        openingTask = Task { [weak self] in
            guard let openPane = self?.openPane else { return }
            let opened = await openPane(url)
            guard !Task.isCancelled, let self else { return }
            if opened {
                self.tracker.start()
            } else {
                self.isWaiting = false
                self.openingFailed = true
                self.rebuildContent()
            }
        }
    }

    private func showPanel() {
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else { return }
        if panel == nil {
            let panel = PermissionGuidePanel(
                contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 96),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = ThemePalette.clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.keepSettingsVisible = { SystemPermissionSettings().activateSettings() }
            self.panel = panel
        }
        rebuildContent()
        guard let panel else { return }
        panel.ignoresMouseEvents = false
        let mouse = NSEvent.mouseLocation
        let visible = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? panel.frame
        let origin = CGPoint(
            x: min(max(mouse.x - panel.frame.width / 2, visible.minX), visible.maxX - panel.frame.width),
            y: min(max(mouse.y - panel.frame.height, visible.minY), visible.maxY - panel.frame.height)
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func refreshInterfaceLanguage() {
        guard panel?.isVisible == true else { return }
        rebuildContent()
    }

    private func rebuildContent() {
        guard let panel, let permission else { return }
        let rootView = PermissionGuideView(
            permission: permission,
            appURL: Bundle.main.bundleURL,
            width: panelWidth,
            isWaiting: isWaiting,
            openingFailed: openingFailed,
            isSettingsFrontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences",
            reopen: { [weak self] in self?.openSettings() },
            close: { [weak self] in self?.close(returnToPreviousApp: true) },
            onDragStateChange: { [weak panel] dragging in panel?.ignoresMouseEvents = dragging }
        )
        let size = NSHostingView(rootView: ThemedContent(content: rootView)).fittingSize
        // Let the panel drive content sizing so SwiftUI's intrinsic size does not overwrite the panel frame.
        if let hostingView {
            hostingView.rootView = ThemedContent(content: rootView)
        } else {
            let hostingView = NSHostingView(rootView: ThemedContent(content: rootView))
            hostingView.sizingOptions = []
            self.hostingView = hostingView
            panel.contentView = hostingView
        }
        panel.setContentSize(size)
    }

    func close(ifOwnedBy owner: AnyObject) {
        guard self.owner === owner else { return }
        close()
    }

    func close(returnToPreviousApp: Bool = false) {
        openingTask?.cancel()
        openingTask = nil
        tracker.stop()
        owner = nil
        permission = nil
        onGranted = nil
        panel?.orderOut(nil)
        if returnToPreviousApp {
            previousApplication?.activate(options: [.activateAllWindows])
        }
    }

    private func placePanel(near settingsFrame: CGRect, animate: Bool = false) {
        guard let panel else { return }
        let screen = NSScreen.screens.max {
            let first = $0.frame.intersection(settingsFrame)
            let second = $1.frame.intersection(settingsFrame)
            return first.width * first.height < second.width * second.height
        }
        let visible = screen?.visibleFrame ?? settingsFrame
        panelWidth = min(max(Design.PermissionGuide.minimumWidth,
                             settingsFrame.width - Design.PermissionGuide.sidebarWidth),
                         visible.width - Design.Space.xl)
        rebuildContent()
        let target = Self.panelFrame(size: panel.frame.size, beside: settingsFrame, in: visible)
        let shouldAnimate = animate && !didAttach && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        didAttach = true
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Design.PermissionGuide.launchDuration
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    static func panelFrame(size: CGSize, beside settingsFrame: CGRect, in visible: CGRect) -> CGRect {
        let gap = Design.Space.s
        let trailingX = min(max(settingsFrame.maxX - size.width, visible.minX), visible.maxX - size.width)
        let centerY = min(max(settingsFrame.midY - size.height / 2, visible.minY), visible.maxY - size.height)
        let candidates = [
            CGPoint(x: trailingX, y: settingsFrame.minY - size.height - gap),
            CGPoint(x: settingsFrame.maxX + gap, y: centerY),
            CGPoint(x: settingsFrame.minX - size.width - gap, y: centerY),
            CGPoint(x: trailingX, y: settingsFrame.maxY + gap)
        ]
        for origin in candidates {
            let candidate = CGRect(origin: origin, size: size)
            if visible.contains(candidate) { return candidate }
        }
        return CGRect(x: trailingX, y: visible.minY, width: size.width, height: size.height)
    }
}

@MainActor
protocol PermissionWindowTracking: AnyObject {
    var onFrameChange: ((CGRect) -> Void)? { get set }
    var onSettingsClosed: (() -> Void)? { get set }
    var onPoll: (() -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
private final class SettingsWindowTracker: PermissionWindowTracking {
    var onPoll: (() -> Void)?
    var onFrameChange: ((CGRect) -> Void)?
    var onSettingsClosed: (() -> Void)?

    private var timer: Timer?
    private var settingsPID: pid_t?
    private var missingWindowCount = 0
    private(set) var currentFrame: CGRect?
    private var hasSeenWindow = false
    private var trackingStartTime = 0.0

    func start() {
        stop()
        trackingStartTime = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        settingsPID = nil
        missingWindowCount = 0
        currentFrame = nil
        hasSeenWindow = false
    }

    private func refresh() {
        guard timer != nil else { return }
        onPoll?()
        guard timer != nil else { return }
        if settingsPID == nil {
            settingsPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
                .first(where: { !$0.isTerminated })?.processIdentifier
        }

        guard let settingsPID else {
            closeIfSettingsWindowNeverAppears()
            return
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let frame = windows.compactMap { window -> CGRect? in
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == settingsPID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary)
            else { return nil }
            return appKitFrame(fromGlobalTopLeftFrame: bounds)
        }.filter { $0.width > 300 && $0.height > 250 }
            .max(by: { $0.width * $0.height < $1.width * $1.height })

        if let frame {
            hasSeenWindow = true
            missingWindowCount = 0
            if frame != currentFrame {
                currentFrame = frame
                onFrameChange?(frame)
            }
        } else {
            guard hasSeenWindow else {
                closeIfSettingsWindowNeverAppears()
                return
            }
            missingWindowCount += 1
            if missingWindowCount >= 10 {
                onSettingsClosed?()
            }
        }
    }

    private func closeIfSettingsWindowNeverAppears() {
        guard ProcessInfo.processInfo.systemUptime - trackingStartTime >= 30 else { return }
        onSettingsClosed?()
    }

    private func appKitFrame(fromGlobalTopLeftFrame frame: CGRect) -> CGRect {
        let screens = NSScreen.screens.compactMap { screen -> (frame: CGRect, cgBounds: CGRect)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (screen.frame, CGDisplayBounds(CGDirectDisplayID(number.uint32Value)))
        }
        guard let screen = screens
            .filter({ $0.cgBounds.intersects(frame) })
            .max(by: {
                let first = $0.cgBounds.intersection(frame)
                let second = $1.cgBounds.intersection(frame)
                return first.width * first.height < second.width * second.height
            })
        else { return frame }

        let localX = frame.minX - screen.cgBounds.minX
        let localY = frame.minY - screen.cgBounds.minY
        return CGRect(
            x: screen.frame.minX + localX,
            y: screen.frame.maxY - localY - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
}

private struct PermissionGuideView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    let permission: PermissionGuide.Permission
    let appURL: URL
    let width: CGFloat
    let isWaiting: Bool
    let openingFailed: Bool
    let isSettingsFrontmost: Bool
    let reopen: () -> Void
    let close: () -> Void
    let onDragStateChange: (Bool) -> Void
    @State private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Design.PermissionGuide.contentSpacing) {
            HStack(alignment: .top, spacing: Design.PermissionGuide.headerSpacing) {
                if isWaiting {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("openingSystemSettings"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Image(systemName: openingFailed ? "exclamationmark.triangle" : "arrowshape.up.fill")
                        .foregroundStyle(.tint)
                        .tint(theme.isSystem ? nil : theme.swiftUI.accentFill)
                        .symbolEffect(.pulse, isActive: isDragging && !reduceMotion)
                        .modifier(PermissionGuideWiggle(isActive: !openingFailed && !isDragging && !reduceMotion))
                    Text(openingFailed ? L10n.text("couldNotOpenSystemSettingsTryAgain") :
                         L10n.format("permission.dragToAllow", permission.title))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !isSettingsFrontmost || openingFailed {
                    Button(L10n.text("reopenSystemSettings"), systemImage: "gear", action: reopen)
                        .labelStyle(.iconOnly)
                        .font(Design.PermissionGuide.actionFont)
                        .help(L10n.text("reopenSystemSettings"))
                }
                Button(L10n.text("closeGuide"), systemImage: "xmark.circle.fill", action: close)
                    .labelStyle(.iconOnly)
                    .font(Design.PermissionGuide.closeFont)
                    .help(L10n.text("closeGuide"))
            }
            .font(Design.PermissionGuide.headingFont)
            .buttonStyle(.borderless)

            if !isWaiting && !openingFailed {
                AppBundleDragCard(url: appURL) { dragging in
                    isDragging = dragging
                    onDragStateChange(dragging)
                }
                .frame(height: Design.PermissionGuide.cardHeight)
                if let hint = permission.restartHint {
                    Text(hint).font(Design.Text.note.font).foregroundStyle(ThemeStyle.nativeSecondary)
                }
            }
        }
        .padding(.top, Design.Space.s)
        .padding(.bottom, Design.Space.m)
        .padding(.horizontal, Design.Space.m)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Design.PermissionGuide.radius))
    }
}

private struct PermissionGuideWiggle: ViewModifier {
    let isActive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.symbolEffect(.wiggle, options: .repeating, isActive: isActive)
        } else if isActive {
            content.keyframeAnimator(initialValue: 0.0, repeating: true) { image, angle in
                image.rotationEffect(.degrees(angle))
            } keyframes: { _ in
                CubicKeyframe(-Design.PermissionGuide.wiggleAngle, duration: Design.PermissionGuide.wiggleStep)
                CubicKeyframe(Design.PermissionGuide.wiggleAngle, duration: Design.PermissionGuide.wiggleStep * 2)
                CubicKeyframe(0, duration: Design.PermissionGuide.wiggleStep)
            }
        } else {
            content
        }
    }
}

private final class PermissionGuidePanel: NSPanel {
    var keepSettingsVisible: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            keepSettingsVisible?()
        }
        super.sendEvent(event)
    }
}

private struct AppBundleDragCardContent: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageState.shared
    let url: URL

    var body: some View {
        HStack(spacing: Design.Space.s) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.fileSystemPath))
                .resizable()
                .frame(width: Design.PermissionGuide.iconSize, height: Design.PermissionGuide.iconSize)
                .accessibilityHidden(true)
            Text(url.deletingPathExtension().lastPathComponent)
                .font(Design.Text.content.font)
                .lineLimit(1)
            Spacer()
            VStack(spacing: 0) {
                Image(systemName: "hand.draw").font(Design.PermissionGuide.headingFont)
                Text(L10n.text("drag")).font(Design.PermissionGuide.dragLabelFont)
            }
            .foregroundStyle(ThemeStyle.nativeSecondary)
            .padding(.trailing, Design.PermissionGuide.cardInset)
        }
        .padding(Design.PermissionGuide.cardInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeStyle.permissionCardFill,
                    in: RoundedRectangle(cornerRadius: Design.PermissionGuide.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Design.PermissionGuide.cardRadius)
                .strokeBorder(ThemeStyle.permissionCardStroke)
        }
    }
}

private struct AppBundleDragCard: NSViewRepresentable {
    let url: URL
    let onDragStateChange: (Bool) -> Void

    func makeNSView(context: Context) -> AppBundleDragSourceView {
        let view = AppBundleDragSourceView(url: url)
        view.onDragStateChange = onDragStateChange
        return view
    }

    func updateNSView(_ nsView: AppBundleDragSourceView, context: Context) {
        nsView.url = url
        nsView.onDragStateChange = onDragStateChange
    }
}

private final class AppBundleDragSourceView: NSView, NSDraggingSource {
    var url: URL
    var onDragStateChange: ((Bool) -> Void)?
    private var mouseDownPoint: NSPoint?

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        let content = NSHostingView(rootView: ThemedContent(content: AppBundleDragCardContent(url: url)).allowsHitTesting(false))
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.text("dragTheAppIntoThePermissionList"))
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - startPoint.x, point.y - startPoint.y) > 4 else { return }

        let writer = AppBundlePasteboardWriter(url: url)
        let item = NSDraggingItem(pasteboardWriter: writer)
        let icon = NSWorkspace.shared.icon(forFile: url.fileSystemPath)
        icon.size = NSSize(width: 56, height: 56)
        let dragPoint = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: dragPoint.x - 28, y: dragPoint.y - 28, width: 56, height: 56), contents: icon)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        mouseDownPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { onDragStateChange?(true) }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { onDragStateChange?(false) }
}

private final class AppBundlePasteboardWriter: NSObject, NSPasteboardWriting {
    private let url: URL
    init(url: URL) { self.url = url }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .fileURL ? url.absoluteString : nil
    }
}
