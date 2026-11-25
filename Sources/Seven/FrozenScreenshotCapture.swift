import AppKit
import CoreGraphics

/// 每张冻结图对应一个屏幕，框选完成后按该屏幕的像素坐标从原图裁剪。
struct FrozenScreenshotFrame: Sendable {
    let screenFrame: CGRect
    let image: CGImage

    func croppedImage(in localRect: CGRect, independentPixels: Bool = false) -> NSImage? {
        let rect = localRect.intersection(CGRect(origin: .zero, size: screenFrame.size))
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        let pixels = ScreenshotGeometry.displayRect(
            for: rect, screenSize: screenFrame.size,
            displaySpaceSize: CGSize(width: image.width, height: image.height)
        )
        guard let cropped = image.cropping(to: pixels) else { return nil }
        if independentPixels, cropped.width != image.width || cropped.height != image.height,
           let bitmap = Self.copyPixels(from: cropped) {
            return NSImage(cgImage: bitmap, size: rect.size)
        }
        return NSImage(cgImage: cropped, size: rect.size)
    }

    private static func copyPixels(from image: CGImage) -> CGImage? {
        guard let colorSpace = image.colorSpace,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: image.bitmapInfo) else { return nil }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

/// 翻译/识别沿用同一框选器，但不暴露截图专用操作，也不借改全局偏好实现。
enum FrozenCapturePurpose: String {
    case screenshot, translation, ocr, scroll
    var isTextSelection: Bool { self == .translation || self == .ocr }
    var previousAreaKey: String { self == .screenshot ? "screenshotPreviousArea.v1" : "\(rawValue).previousArea.v1" }
    var smartSelectionKey: String { isTextSelection ? "\(rawValue).smartSelection.v1" : ScreenshotToolPreferences.smartSelectionKey }
    func smartSelectionEnabled(in defaults: UserDefaults, accessibilityGranted: Bool) -> Bool {
        accessibilityGranted && (defaults.object(forKey: smartSelectionKey) as? Bool ?? true)
    }
    func permits(_ command: FrozenSelectionCommand) -> Bool {
        if self == .scroll { return command != .copyColor }
        return !isTextSelection || command == .cancel || command == .previousArea
    }
}

/// 截图辅助键分别为 R 恢复上次区域、F 全屏和 C 拷贝当前 HEX 色值。
enum FrozenSelectionCommand: Equatable {
    case cancel, fullScreen, previousArea, copyColor
    init?(keyCode: UInt16) {
        switch keyCode {
        case 53: self = .cancel
        case 3: self = .fullScreen
        case 15: self = .previousArea
        case 8: self = .copyColor
        default: return nil
        }
    }
}

@MainActor
protocol FrozenScreenshotCapturing {
    func freezeScreens() async throws -> [FrozenScreenshotFrame]
}

@MainActor
final class FrozenScreenshotCaptureCoordinator {
    func refreshInterfaceLanguage() {
        for panel in panels {
            (panel.contentView as? FrozenSelectionView)?.refreshInterfaceLanguage()
        }
    }

    typealias Completion = (Result<NSImage, ScreenshotTranslationError>) -> Void
    private let capture: FrozenScreenshotCapturing
    private let hasPermission: () -> Bool
    private let hasAccessibilityPermission: () -> Bool
    private let defaults: UserDefaults
    private let windowCapture: IndependentWindowCapturing
    private let windowCandidatesProvider: (() -> [FrozenWindowCandidate])?
    private var multiSelection = FrozenMultiWindowSelection()
    private var freezeTask: Task<Void, Never>?
    private var windowCaptureTask: Task<Void, Never>?
    private static let previousAreaKey = "screenshotPreviousArea.v1"
    private var purpose = FrozenCapturePurpose.screenshot
    private var panels: [NSPanel] = []
    private var completion: Completion?
    private var captureGeneration: UUID?
    private var cursorIsPushed = false
    private(set) var lastCaptureRect: CGRect?
    private(set) var lastCaptureScreenFrame: CGRect?
    /// 仅在截图成功回调内供编辑器接管，整屏像素由会话或编辑器持有。
    private(set) var lastSelectionContext: FrozenSelectionContext?
    var isCapturing: Bool { captureGeneration != nil }

    init(capture: FrozenScreenshotCapturing? = nil,
         hasPermission: @escaping () -> Bool = CGPreflightScreenCaptureAccess,
         defaults: UserDefaults = .standard,
         windowCapture: IndependentWindowCapturing? = nil,
         windowCandidatesProvider: (() -> [FrozenWindowCandidate])? = nil,
         hasAccessibilityPermission: @escaping () -> Bool = { SelectionReader.isAccessibilityTrusted }) {
        self.windowCandidatesProvider = windowCandidatesProvider
        self.windowCapture = windowCapture ?? SystemIndependentWindowCapture()
        self.capture = capture ?? SystemFrozenScreenshotCapture()
        self.hasPermission = hasPermission
        self.hasAccessibilityPermission = hasAccessibilityPermission
        self.defaults = defaults
    }

    func start(purpose: FrozenCapturePurpose = .screenshot, completion: @escaping Completion) {
        guard prepareCapture(completion) else { return }
        self.purpose = purpose
        freeze(completion) { coordinator, frames, token in
            guard !frames.isEmpty else {
                coordinator.finish(.failure(.captureFailed), token: token)
                return
            }
            coordinator.showSelection(frames: frames, purpose: purpose, token: token)
        }
    }

    private func showSelection(frames: [FrozenScreenshotFrame], purpose: FrozenCapturePurpose, token: UUID) {
        let mouse = NSEvent.mouseLocation
        let candidates: [FrozenWindowCandidate]
        if let windowCandidatesProvider { candidates = windowCandidatesProvider() }
        else {
            let windowInfo = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            let translationWindows = Set(NSApp.windows.filter { $0 is TranslationPanel && $0.isVisible }.compactMap { $0.windowNumber > 0 ? CGWindowID($0.windowNumber) : nil })
            candidates = FrozenWindowCandidate.candidates(from: windowInfo, primaryScreenTop: NSScreen.screens.first?.frame.maxY ?? 0, includingWindowIDs: translationWindows)
        }
        multiSelection = FrozenMultiWindowSelection()
        let smartSelectionEnabled = purpose.smartSelectionEnabled(in: defaults, accessibilityGranted: hasAccessibilityPermission())
        for frame in frames {
            let panel = FrozenSelectionPanel(contentRect: frame.screenFrame,
                                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.animationBehavior = .none
            panel.isReleasedWhenClosed = false
            panel.level = .screenSaver
            panel.hasShadow = false
            panel.isOpaque = true
            panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = FrozenSelectionView(frame: CGRect(origin: .zero, size: frame.screenFrame.size), image: frame.image,
                                                   screenFrame: frame.screenFrame, candidates: candidates, smartSelectionEnabled: smartSelectionEnabled, outputCornerRadius: purpose.isTextSelection ? 0 : ScreenshotToolPreferences(defaults: defaults).outputCornerRadius,capturePreferences:ScreenshotCapturePreferences(defaults:defaults), purpose: purpose,
                                                   fullScreen: { [weak self] in
                self?.finishArea(CGRect(origin: .zero, size: frame.screenFrame.size), in: frame, token: token)
            }, previousArea: { [weak self] in
                guard let self, self.captureGeneration == token,
                      let saved = self.defaults.string(forKey: self.purpose.previousAreaKey) else { NSSound.beep(); return }
                let previous = NSRectFromString(saved)
                guard previous != .zero else { NSSound.beep(); return }
                self.finishArea(Self.previousArea(previous, fitting: frame.screenFrame.size), in: frame, token: token)
            }, toggleWindow: { [weak self] candidate in
                guard let self, self.captureGeneration == token else { return }
                self.multiSelection.toggle(candidate, on: frame.screenFrame)
                self.refreshSelectedWindows(candidates)
            }, finishWindows: { [weak self] in
                guard let self, self.captureGeneration == token, let screen = self.multiSelection.screenFrame else { return }
                let windows = self.multiSelection.ordered(in: candidates)
                guard !windows.isEmpty else { return }
                self.captureSelectedWindows(windows, screenFrame: screen, backgroundImage: frames.first { $0.screenFrame == screen }?.image, token: token)
            }) { [weak self] rect, candidate in
                guard let self, self.captureGeneration == token else { return }
                if let candidate {
                    self.captureSelectedWindows([candidate], screenFrame: frame.screenFrame, backgroundImage: frame.image, token: token)
                    return
                }
                guard let rect else { self.finish(.failure(.cancelled), token: token); return }
                self.finishArea(rect, in: frame, token: token)
            }
            panels.append(panel)
            if frame.screenFrame.contains(mouse) {
                (panel.contentView as? FrozenSelectionView)?.refreshHover(at: CGPoint(x: mouse.x - frame.screenFrame.minX, y: mouse.y - frame.screenFrame.minY))
            }
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.display()
        }
        for panel in panels {
            if panel.frame.contains(mouse) {
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(panel.contentView)
            } else { panel.orderFrontRegardless() }
        }
        NSCursor.crosshair.push()
        cursorIsPushed = true
    }

    func captureFullScreen(completion: @escaping Completion) {
        guard prepareCapture(completion) else { return }
        let mouse = NSEvent.mouseLocation
        freeze(completion) { coordinator, frames, token in
            guard let frame = frames.first(where: { $0.screenFrame.contains(mouse) }) ?? frames.first else {
                coordinator.finish(.failure(.captureFailed), token: token)
                return
            }
            coordinator.lastCaptureRect = frame.screenFrame
            coordinator.lastCaptureScreenFrame = frame.screenFrame
            let context = FrozenSelectionContext(screenFrame: frame.screenFrame,
                localSelection: CGRect(origin: .zero, size: frame.screenFrame.size), image: frame.image)
            let image = NSImage(cgImage: frame.image, size: frame.screenFrame.size)
            coordinator.finish(.success(image), token: token, editorContext: context)
        }
    }

    /// 导出时保存上次区域，取消编辑时保留已保存的区域。
    func rememberArea(_ globalRect: CGRect, on screenFrame: CGRect) {
        let local = globalRect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        defaults.set(NSStringFromRect(local), forKey: Self.previousAreaKey)
    }

    /// 在当前屏幕复用上次区域，超出边界时移动原点并保留尺寸。
    static func previousArea(_ rect: CGRect, fitting size: CGSize) -> CGRect {
        var adjusted = rect
        if adjusted.maxX > size.width { adjusted.origin.x = size.width - adjusted.width }
        if adjusted.maxY > size.height { adjusted.origin.y = size.height - adjusted.height }
        return adjusted
    }

    var hasPreviousArea: Bool {
        guard let value = defaults.string(forKey: Self.previousAreaKey) else { return false }
        return NSRectFromString(value) != .zero
    }

    func capturePreviousArea(completion: @escaping Completion) {
        guard prepareCapture(completion) else { return }
        guard let saved = defaults.string(forKey: Self.previousAreaKey) else { NSSound.beep(); return }
        let previous = NSRectFromString(saved)
        guard previous != .zero else { NSSound.beep(); return }
        let mouse = NSEvent.mouseLocation
        freeze(completion) { coordinator, frames, token in
            guard let frame = frames.first(where: { $0.screenFrame.contains(mouse) }) ?? frames.first else {
                coordinator.finish(.failure(.captureFailed), token: token)
                return
            }
            let local = Self.previousArea(previous, fitting: frame.screenFrame.size)
            guard let image = frame.croppedImage(in: local) else {
                coordinator.finish(.failure(.captureFailed), token: token)
                return
            }
            coordinator.lastCaptureRect = local.offsetBy(dx: frame.screenFrame.minX, dy: frame.screenFrame.minY)
            coordinator.lastCaptureScreenFrame = frame.screenFrame
            let context = FrozenSelectionContext(screenFrame: frame.screenFrame, localSelection: local, image: frame.image)
            coordinator.finish(.success(image), token: token, editorContext: context)
        }
    }

    private func prepareCapture(_ completion: Completion) -> Bool {
        cancel()
        // 取消回调可以同步开启另一会话。
        guard captureGeneration == nil else { completion(.failure(.cancelled)); return false }
        guard hasPermission() else { completion(.failure(.permissionDenied)); return false }
        return true
    }

    private func freeze(_ completion: @escaping Completion,
                        receive: @escaping (FrozenScreenshotCaptureCoordinator, [FrozenScreenshotFrame], UUID) -> Void) {
        let token = UUID()
        captureGeneration = token
        self.completion = completion
        freezeTask = Task { [weak self, capture] in
            do {
                try Task.checkCancellation()
                let frames = try await capture.freezeScreens()
                guard let self, self.captureGeneration == token, !Task.isCancelled else { return }
                self.freezeTask = nil
                autoreleasepool { receive(self, frames, token) }
            } catch {
                guard let self, self.captureGeneration == token, !Task.isCancelled else { return }
                self.finish(.failure(.captureFailed), token: token)
            }
        }
    }

    func cancel() {
        guard let captureGeneration else { return }
        finish(.failure(.cancelled), token: captureGeneration)
    }

    private func finishArea(_ rect: CGRect, in frame: FrozenScreenshotFrame, token: UUID) {
        guard captureGeneration == token else { return }
        guard let image = frame.croppedImage(in: rect, independentPixels: purpose == .ocr) else {
            finish(.failure(.captureFailed), token: token)
            return
        }
        lastCaptureRect = rect.offsetBy(dx: frame.screenFrame.minX, dy: frame.screenFrame.minY)
        lastCaptureScreenFrame = frame.screenFrame
        if purpose != .screenshot { defaults.set(NSStringFromRect(rect), forKey: purpose.previousAreaKey) }
        let editorContext = purpose == .screenshot
            ? FrozenSelectionContext(screenFrame: frame.screenFrame, localSelection: rect, image: frame.image)
            : nil
        finish(.success(image), token: token, editorContext: editorContext)
    }

    private func refreshSelectedWindows(_ candidates: [FrozenWindowCandidate]) {
        let selected = multiSelection.ordered(in: candidates)
        for panel in panels { (panel.contentView as? FrozenSelectionView)?.selectedWindows = selected }
    }

    /// 与交互共用的多窗口捕获入口，便于隔离后端验证错误和取消。
    func captureWindows(_ candidates: [FrozenWindowCandidate], on screenFrame: CGRect, completion: @escaping Completion) {
        guard prepareCapture(completion) else { return }
        guard !candidates.isEmpty else { completion(.failure(.captureFailed)); return }
        freeze(completion) { coordinator, frames, token in
            let background = frames.first { $0.screenFrame == screenFrame }?.image
            coordinator.captureSelectedWindows(candidates, screenFrame: screenFrame, backgroundImage: background, token: token)
        }
    }

    private func captureSelectedWindows(_ candidates: [FrozenWindowCandidate], screenFrame: CGRect, backgroundImage: CGImage?, token: UUID) {
        guard windowCaptureTask == nil, !candidates.isEmpty else { return }
        // 独立窗口后端按 WindowID 采集，无需隐藏覆盖层；一直保留冻结桌面到编辑器接手。
        panels.forEach { ($0.contentView as? FrozenSelectionView)?.beginWindowCapture() }
        windowCaptureTask = Task { [weak self] in
            guard let self else { return }
            do {
                var images: [NSImage] = []
                for candidate in candidates {
                    try Task.checkCancellation()
                    images.append(try await self.windowCapture.capture(candidate))
                }
                guard self.captureGeneration == token, !Task.isCancelled else { return }
                guard let context = FrozenMultiWindowComposition.selectionContext(candidates: candidates, images: images, screenFrame: screenFrame, backgroundImage: backgroundImage),
                      let image = context.croppedImage(in: context.localSelection) else { throw ScreenshotTranslationError.captureFailed }
                self.lastCaptureRect = nil; self.lastCaptureScreenFrame = nil
                self.finish(.success(image), token: token, editorContext: context)
            } catch {
                guard self.captureGeneration == token, !Task.isCancelled else { return }
                self.finish(.failure(.captureFailed), token: token)
            }
        }
    }

    private func deliver(_ image: NSImage, editorContext: FrozenSelectionContext?, to callback: Completion?) {
        let previousContext = lastSelectionContext
        lastSelectionContext = editorContext
        defer { lastSelectionContext = previousContext }
        callback?(.success(image))
    }

    private func finish(_ result: Result<NSImage, ScreenshotTranslationError>, token: UUID,
                        editorContext: FrozenSelectionContext? = nil) {
        guard captureGeneration == token else { return }
        captureGeneration = nil
        freezeTask?.cancel(); freezeTask = nil
        windowCaptureTask?.cancel(); windowCaptureTask = nil
        let callback = completion
        completion = nil
        let oldPanels = panels
        oldPanels.forEach { ($0.contentView as? FrozenSelectionView)?.cancelSmartSelection() }
        panels.removeAll()
        if cursorIsPushed { NSCursor.pop(); cursorIsPushed = false }
        switch result {
        case .success(let image):
            // 先显示编辑器再关闭选择层，避免交接时桌面曝光。
            deliver(image, editorContext: editorContext, to: callback)
            oldPanels.forEach { $0.close() }
        case .failure:
            // 错误回调可能显示模态提示，先移除位于最上层的选择窗口。
            oldPanels.forEach { $0.close() }
            callback?(result)
        }
    }

}

private final class FrozenSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class FrozenSelectionView: ThemedDrawingView {
    private let image: NSImage
    private let complete: (CGRect?, FrozenWindowCandidate?) -> Void
    private let fullScreen: () -> Void
    private let previousArea: () -> Void
    private let toggleWindow: (FrozenWindowCandidate) -> Void
    private let finishWindows: () -> Void
    private let writeColor: (String) -> Bool
    var selectedWindows: [FrozenWindowCandidate] = [] { didSet { needsDisplay = true } }
    private var commandHeld = false
    private var pointer: CGPoint?
    private let guides: FrozenCaptureGuidesView
    private let screenFrame: CGRect
    private let candidates: [FrozenWindowCandidate]
    private var hovered: FrozenWindowCandidate?
    private let smartSelectionEnabled: Bool
    private let smartSelector: any FrozenSmartSelecting
    private let smartGeometry: FrozenSmartGeometry
    private var smartCache = FrozenSmartSelectionCache()
    private let capturePreferences:ScreenshotCapturePreferences
    private let purpose: FrozenCapturePurpose
    private var manualHierarchyPoint:CGPoint?
    private var smartTarget: FrozenSmartRegion?
    private var lastSmartPoint: CGPoint?
    private var lastSmartWindow: FrozenWindowCandidate?
    private var smartRect: CGRect? {
        smartTarget.map { $0.frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY).intersection(bounds) }
    }
    private var smartQueryTask: Task<Void, Never>?
    private var smartSelectionActive = true
    private var anchor: CGPoint?
    private var dragged = false
    private var awaitingWindowCapture = false
    private(set) var selection = CGRect.zero
    private var tracking: NSTrackingArea?
    private let outputCornerRadius: CGFloat
    private let sourceImage: CGImage
    private let magnifier = FrozenMagnifierView()

    init(frame: CGRect, image: CGImage, screenFrame: CGRect, candidates: [FrozenWindowCandidate], smartSelectionEnabled: Bool = true,
         smartSelector: any FrozenSmartSelecting = SystemFrozenSmartSelection(),
         primaryScreenTop: CGFloat? = nil, outputCornerRadius: CGFloat = 0,capturePreferences:ScreenshotCapturePreferences = ScreenshotCapturePreferences(), purpose: FrozenCapturePurpose = .screenshot,
         fullScreen: @escaping () -> Void, previousArea: @escaping () -> Void,
         toggleWindow: @escaping (FrozenWindowCandidate) -> Void = { _ in }, finishWindows: @escaping () -> Void = {},
         writeColor: @escaping (String) -> Bool = { value in
             NSPasteboard.general.clearContents()
             return NSPasteboard.general.setString(value, forType: .string)
         },
         complete: @escaping (CGRect?, FrozenWindowCandidate?) -> Void) {
        self.capturePreferences=capturePreferences
        self.purpose = purpose
        self.smartSelectionEnabled = smartSelectionEnabled; self.smartSelector = smartSelector
        self.smartGeometry = FrozenSmartGeometry(screenFrame: screenFrame,
            pixelSize: CGSize(width: image.width, height: image.height),
            primaryScreenTop: primaryScreenTop ?? NSScreen.screens.first?.frame.maxY ?? screenFrame.maxY)
        self.guides = FrozenCaptureGuidesView(frame: CGRect(origin: .zero, size: frame.size))
        self.toggleWindow = toggleWindow; self.finishWindows = finishWindows
        self.writeColor = writeColor
        self.sourceImage = image
        self.outputCornerRadius = outputCornerRadius
        self.image = NSImage(cgImage: image, size: frame.size)
        self.screenFrame = screenFrame; self.candidates = candidates
        self.complete = complete
        self.fullScreen = fullScreen; self.previousArea = previousArea
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        guides.showsCrosshair = !purpose.isTextSelection && capturePreferences.crosshair
        guides.showsHints = purpose.isTextSelection || capturePreferences.hints
        refreshInterfaceLanguage()
        addSubview(guides)
        addSubview(magnifier)
    }

    func refreshInterfaceLanguage() {
        guides.shortcuts = FrozenCaptureGuidesView.shortcuts
        guides.hintTitle = L10n.text("screenshotShortcuts")
        magnifier.setAccessibilityLabel(L10n.text("pixelMagnifier"))
        if purpose.isTextSelection { guides.shortcuts = [("R", L10n.text("capture.previousArea"))]; guides.hintTitle = L10n.text("selectionShortcuts") }
        if purpose == .scroll { guides.shortcuts = [("R", L10n.text("capture.previousArea")), ("F", L10n.text("selectFullScreen")), ("⇧", L10n.text("holdToCaptureASquareArea"))]; guides.hintTitle = L10n.text("scrollingScreenshotArea") }
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        guard anchor == nil else { return }
        refreshHover(at: convert(event.locationInWindow, from: nil))
    }
    func refreshHover(at point: CGPoint) {
        guard !awaitingWindowCapture else { return }
        pointer = point; guides.updatePointer(point)
        let global = smartGeometry.point(CGPoint(x: point.x + screenFrame.minX, y: point.y + screenFrame.minY))
        let candidate = candidates.first { $0.frame.contains(global) }
        let changedWindow = hovered?.id != candidate?.id
        if let manual=manualHierarchyPoint,changedWindow || hypot(manual.x-global.x,manual.y-global.y)>FrozenSmartRegion.manualSelectionResetDistance {manualHierarchyPoint=nil;smartTarget=nil;lastSmartPoint=nil}
        if changedWindow { lastSmartPoint = nil }
        if changedWindow || smartTarget?.frame.contains(global) == false { smartTarget = nil }
        hovered = candidate
        if !smartSelectionEnabled || commandHeld || changedWindow || candidate?.ownerPID == nil { selection = hoverFallbackRect }
        else if let smartRect { selection = smartRect }
        // 同窗口内保留当前显示，等新命中一次性替换，避免先闪回整窗。
        updateMagnifier(at:point)
        needsDisplay = true
        requestSmartSelection()
    }
    private var windowRect: CGRect {
        hovered?.frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY).intersection(bounds) ?? .zero
    }
    /// 桌面不是普通窗口：没有窗口命中时选当前屏幕，多窗口模式中桌面不作为目标。
    private var hoverFallbackRect: CGRect {
        if hovered != nil { return windowRect }
        return !commandHeld && pointer.map(bounds.contains) == true ? bounds : .zero
    }
    private func requestSmartSelection() {
        guard manualHierarchyPoint == nil,smartSelectionActive, smartSelectionEnabled, !commandHeld, anchor == nil,
              let point = pointer, let candidate = hovered, candidate.ownerPID != nil else { return }
        let global = smartGeometry.point(CGPoint(x: point.x + screenFrame.minX, y: point.y + screenFrame.minY))
        if let target = smartCache.element(at: global, in: candidate) {
            smartTarget = target
            selection = smartRect ?? windowRect
            needsDisplay = true
            if target.isTerminal { return }
        }
        guard smartQueryTask == nil else { return }
        if lastSmartPoint == global, lastSmartWindow == candidate { return }
        lastSmartPoint = global; lastSmartWindow = candidate
        let selector = smartSelector, geometry = smartGeometry
        smartQueryTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let result = await selector.regions(at: global, in: candidate, geometry: geometry)
            guard !Task.isCancelled, let self, self.smartSelectionActive else { return }
            self.smartQueryTask = nil
            if self.manualHierarchyPoint == nil,self.anchor == nil, !self.commandHeld, self.hovered == candidate, let currentPoint = self.pointer {
                let currentGlobal = geometry.point(CGPoint(x: currentPoint.x + self.screenFrame.minX, y: currentPoint.y + self.screenFrame.minY))
                let previousTarget = self.smartTarget
                let target = self.smartCache.target(at: currentGlobal, in: candidate, result: result, retaining: previousTarget)
                if let target, target.frame.contains(currentGlobal) {
                    self.smartTarget = target
                }
                self.selection = self.smartRect ?? self.windowRect
                self.needsDisplay = true
                if currentGlobal != global { self.requestSmartSelection() }
            } else if self.hovered != candidate, let pointer = self.pointer, self.bounds.contains(pointer) {
                self.requestSmartSelection()
            }
        }
    }
    private func updateMagnifier(at point:CGPoint) {
        magnifier.update(image:sourceImage,point:point,screenSize:bounds.size)
        if purpose.isTextSelection || !capturePreferences.magnifier {magnifier.isHidden=true}
    }
    override func scrollWheel(with event:NSEvent) {
        guard !awaitingWindowCapture,smartSelectionEnabled,!commandHeld,anchor==nil,let point=pointer,let window=hovered,event.deltaY != 0 else{return}
        let global=smartGeometry.point(CGPoint(x:point.x+screenFrame.minX,y:point.y+screenFrame.minY))
        let chain=smartCache.hierarchy(at:global,in:window)
        guard chain.count>1 else{return}
        let current=chain.firstIndex{$0.frame == smartTarget?.frame} ?? chain.count-1
        let next=min(chain.count-1,max(0,current+(event.deltaY>0 ? 1:-1)))
        smartQueryTask?.cancel();smartQueryTask=nil;manualHierarchyPoint=global
        smartTarget=chain[next];selection=smartRect ?? windowRect;needsDisplay=true
    }
    func cancelSmartSelection() {
        smartSelectionActive = false
        smartQueryTask?.cancel(); smartQueryTask = nil
        smartSelector.finishSession()
    }
    func beginWindowCapture() {
        awaitingWindowCapture = true
        cancelSmartSelection()
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        guard !awaitingWindowCapture, anchor == nil else { return }
        hovered = nil; smartTarget = nil; manualHierarchyPoint=nil;lastSmartPoint = nil; pointer = nil; selection = .zero; magnifier.isHidden = true; guides.updatePointer(nil); needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        var revealed = selectedWindows.map { $0.frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY).intersection(bounds) }
        if !selection.isEmpty { revealed.append(selection) }
        // 窗口点选保留窗口轮廓；拖出的区域从首帧起应用输出圆角。
        let pixels = ScreenshotGeometry.displayRect(for: selection, screenSize: screenFrame.size,
            displaySpaceSize: CGSize(width: sourceImage.width, height: sourceImage.height)).size
        let showingElement = hovered != nil && !selection.isEmpty && selection != windowRect
        let radii = dragged || showingElement && !commandHeld ? ScreenshotSelectionSizing.cornerRadii(outputCornerRadius, logicalSize: selection.size, pixelSize: pixels) : .zero
        FrozenCaptureMask.draw(background: image, in: bounds, revealing: revealed, cornerRadii: radii)
        theme.captureAccent.setStroke()
        let border = NSBezierPath(roundedRect: selection, xRadius: radii.width, yRadius: radii.height)
        border.lineWidth = Design.ScreenshotCapture.borderWidth
        border.stroke()
        for candidate in selectedWindows {
            let selected = candidate.frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY).intersection(bounds)
            theme.captureAccent.setStroke()
            let border = NSBezierPath(rect: selected); border.lineWidth = Design.ScreenshotCapture.cornerWidth; border.stroke()
        }
        // 选区为直角且宽高均超过最小尺寸时，绘制四个 L 形角。
        if radii == .zero, selection.width > Design.ScreenshotCapture.cornerMinimumSize,
           selection.height > Design.ScreenshotCapture.cornerMinimumSize {
            let outside = Design.ScreenshotCapture.cornerOutside
            let inside = Design.ScreenshotCapture.cornerInside
            let left = selection.minX, right = selection.maxX, bottom = selection.minY, top = selection.maxY
            let corners = NSBezierPath()
            for points in [
                [CGPoint(x: left + inside, y: bottom - outside), CGPoint(x: left - outside, y: bottom - outside), CGPoint(x: left - outside, y: bottom + inside)],
                [CGPoint(x: left + inside, y: top + outside), CGPoint(x: left - outside, y: top + outside), CGPoint(x: left - outside, y: top - inside)],
                [CGPoint(x: right - inside, y: top + outside), CGPoint(x: right + outside, y: top + outside), CGPoint(x: right + outside, y: top - inside)],
                [CGPoint(x: right - inside, y: bottom - outside), CGPoint(x: right + outside, y: bottom - outside), CGPoint(x: right + outside, y: bottom + inside)]
            ] {
                corners.move(to: points[0]); corners.line(to: points[1]); corners.line(to: points[2])
            }
            corners.lineWidth = Design.ScreenshotCapture.cornerWidth
            corners.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard !awaitingWindowCapture else { return }
        commandHeld = purpose == .screenshot && event.modifierFlags.contains(.command)
        mouseMoved(with: event)
        // 等待识别时保留的旧框仅作视觉延续，不能作为新位置的截图结果。
        if !commandHeld, smartRect == nil { selection = hoverFallbackRect }
        anchor = convert(event.locationInWindow, from: nil)
        dragged = false
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !awaitingWindowCapture, let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        dragged = true
        smartTarget = nil
        hovered = nil
        pointer = point; guides.updatePointer(point)
        selection = FrozenSquareSelection.rect(from: anchor, to: point, within: bounds, square: !purpose.isTextSelection && event.modifierFlags.contains(.shift))
        updateMagnifier(at:point)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard !awaitingWindowCapture else { return }
        if !dragged, commandHeld {
            if let hovered { toggleWindow(hovered) }
            anchor = nil
            return
        }
        cancelSmartSelection()
        if purpose != .screenshot {
            complete(selection.width > 0 && selection.height > 0 ? selection : nil, nil)
            return
        }
        if !dragged,smartTarget?.role == "AXWindow",let hovered {complete(nil,hovered)}
        else if !dragged, smartRect != nil { complete(selection, nil) }
        else if !dragged, let hovered { complete(nil, hovered) }
        else { complete(selection.width > 0 && selection.height > 0 ? selection : nil, nil) }
    }
    override func flagsChanged(with event: NSEvent) {
        guard !awaitingWindowCapture else { return }
        let held = purpose == .screenshot && event.modifierFlags.contains(.command)
        let released = commandHeld && !held
        commandHeld = held
        lastSmartPoint = nil
        if released { finishWindows() }
        if anchor == nil, let pointer { refreshHover(at: pointer) }
        else if let pointer, let anchor, dragged {
            selection = FrozenSquareSelection.rect(from: anchor, to: pointer, within: bounds, square: !purpose.isTextSelection && event.modifierFlags.contains(.shift))
            needsDisplay = true
        }
    }
    override func rightMouseDown(with event: NSEvent) { cancelSmartSelection(); complete(nil, nil) }
    private func copyColor(_ value: String?) {
        guard let value else { return }
        if writeColor(value) { complete(nil, nil) }
    }
    override func keyDown(with event: NSEvent) {
        let command = FrozenSelectionCommand(keyCode: event.keyCode)
        if awaitingWindowCapture, command != .cancel { return }
        if let command, !purpose.permits(command) { return }
        switch command {
        case .cancel: complete(nil, nil)
        case .fullScreen: fullScreen()
        case .previousArea: previousArea()
        case .copyColor: copyColor(magnifier.hexColor)
        case nil: super.keyDown(with: event)
        }
    }
}
