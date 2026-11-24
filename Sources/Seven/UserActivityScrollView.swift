import AppKit

final class UserActivityScrollView: NSScrollView {
    /// 开始操作时暂停跟随；只有原生滚轮/滚动条操作结束后按实际位置恢复。
    var onUserScroll: ((_ isAtBottom: Bool) -> Void)?
    private var indicatorHideWorkItem: DispatchWorkItem?
    private var userIndicatorActive = false

    func installUserActivityIndicatorPolicy() {
        autohidesScrollers = false
        let scroller = UserActivityScroller()
        scroller.controlSize = .mini
        scroller.activityOwner = self
        verticalScroller = scroller
        scrollerStyle = .overlay
        setIndicatorVisible(false)
    }

    override func tile() {
        super.tile()
        // Keep the viewport independent of AppKit's scroller style negotiation
        // when the view is attached to a window or the system preference changes.
        var viewport = contentView.frame
        viewport.origin.x = 0
        viewport.size.width = bounds.width
        if contentView.frame != viewport { contentView.frame = viewport }
        if let scroller = verticalScroller {
            var frame = scroller.frame
            frame.origin.x = max(0, bounds.width - frame.width)
            scroller.frame = frame
        }
    }

    override func scrollWheel(with event: NSEvent) {
        beginUserIndicatorActivity()
        super.scrollWheel(with: event)
        endUserIndicatorActivity()
    }

    func beginUserIndicatorActivity() {
        onUserScroll?(false)
        indicatorHideWorkItem?.cancel()
        userIndicatorActive = true
        setIndicatorVisible(isVerticallyScrollable)
    }

    func endUserIndicatorActivity() {
        if let documentView {
            let visible = documentVisibleRect
            let atBottom = documentView.isFlipped
                ? visible.maxY >= documentView.bounds.maxY - 1
                : visible.minY <= documentView.bounds.minY + 1
            onUserScroll?(atBottom)
        }
        scheduleIndicatorHide()
    }

    private var isVerticallyScrollable: Bool {
        guard let documentView else { return false }
        return documentView.frame.height > contentView.bounds.height + 1
    }

    private func scheduleIndicatorHide() {
        indicatorHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.userIndicatorActive = false
            self.setIndicatorVisible(false)
        }
        indicatorHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    private func setIndicatorVisible(_ visible: Bool) {
        guard let scroller = verticalScroller else { return }
        scroller.isHidden = !visible
        scroller.alphaValue = visible ? 1 : 0
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        if userIndicatorActive {
            setIndicatorVisible(isVerticallyScrollable)
        } else {
            setIndicatorVisible(false)
        }
    }
}

private final class UserActivityScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    weak var activityOwner: UserActivityScrollView?

    override func mouseDown(with event: NSEvent) {
        activityOwner?.beginUserIndicatorActivity()
        super.mouseDown(with: event)
        activityOwner?.endUserIndicatorActivity()
    }
}
