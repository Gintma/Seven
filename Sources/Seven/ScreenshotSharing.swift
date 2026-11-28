import AppKit

/// Creates a temporary PNG only when the user invokes Share, hands it to the system sharing service, and deletes it on completion or cancellation.
@MainActor final class ScreenshotSharingSession:NSObject,@preconcurrency NSSharingServicePickerDelegate,NSSharingServiceDelegate {
    let fileURL:URL
    private let directory:URL
    private let picker:NSSharingServicePicker
    @MainActor private final class WindowState {
        weak var window:NSWindow?
        let level:NSWindow.Level
        init(_ window:NSWindow) {self.window=window;level=window.level}
    }
    private let sourceWindows:[WindowState]
    private var loweredWindows:[WindowState]=[]
    private let serviceChosen:(()->Void)?
    private let activityChanged:((Bool)->Void)?
    private var serviceStarted=false
    private var keepAlive:ScreenshotSharingSession?
    private(set) var isFinished=false
    init(image:NSImage,temporaryDirectory:URL=FileManager.default.temporaryDirectory,windows:[NSWindow]=[],activityChanged:((Bool)->Void)? = nil,serviceChosen:(()->Void)? = nil) throws {
        sourceWindows=windows.map(WindowState.init);self.activityChanged=activityChanged;self.serviceChosen=serviceChosen
        directory=temporaryDirectory.appending(path: "Seven-Share-\(UUID().uuidString)", directoryHint: .isDirectory)
        fileURL=directory.appending(path: ScreenshotSaving.filename(format:.png), directoryHint: .checkFileSystem)
        guard let data=ScreenshotSaving.data(image,format:.png) else{throw CocoaError(.fileWriteUnknown)}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        do {
            try data.write(to:fileURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:fileURL.fileSystemPath)
        } catch {try? FileManager.default.removeItem(at:directory);throw error}
        picker=NSSharingServicePicker(items:[fileURL])
        super.init();picker.delegate=self
    }
    deinit {try? FileManager.default.removeItem(at:directory)}
    static func present(_ image:NSImage,from view:NSView,current:inout ScreenshotSharingSession?,additionalWindows:[NSWindow]=[],activityChanged:((Bool)->Void)? = nil,serviceChosen:(()->Void)? = nil) {
        guard current == nil || current?.isFinished == true else{return}
        do {
            var roots=additionalWindows
            if var root=view.window {
                while let parent=root.parent {root=parent}
                roots.insert(root,at:0)
            }
            let session=try ScreenshotSharingSession(image:image,windows:roots,activityChanged:activityChanged,serviceChosen:serviceChosen);current=session
            session.keepAlive=session
            // After normal selection completes, focus stays on the canvas; clicking buttons on a non-activating tool panel does not transfer focus automatically.
            // The sharing menu must be presented from the key window; otherwise the first click only renders its appearance and subsequent items fail to take over properly.
            view.window?.makeKey()
            session.picker.show(relativeTo:view.bounds,of:view,preferredEdge:.minY)
        } catch {
            let alert=NSAlert();alert.messageText=L10n.text("couldNotPrepareTheImageForSharing")
            alert.window.level=view.window?.level ?? .normal
            AppAlert.runModal(alert)
        }
    }
    func sharingServicePicker(_ sharingServicePicker:NSSharingServicePicker,delegateFor sharingService:NSSharingService)->(any NSSharingServiceDelegate)? {self}
    func sharingServicePicker(_ sharingServicePicker:NSSharingServicePicker,didChoose service:NSSharingService?) {
        if service == nil {finish()}else{beginService()}
    }
    func sharingService(_ sharingService:NSSharingService,willShareItems items:[Any]) {beginService()}
    func sharingService(_ sharingService:NSSharingService,sourceWindowForShareItems items:[Any],sharingContentScope:UnsafeMutablePointer<NSSharingService.SharingContentScope>)->NSWindow? {serviceChosen == nil ? sourceWindows.first?.window:nil}
    private func beginService() {
        guard !isFinished,!serviceStarted else{return}
        serviceStarted=true;activityChanged?(true)
        var seen=Set<ObjectIdentifier>()
        func collect(_ window:NSWindow) {
            guard window.isVisible,seen.insert(ObjectIdentifier(window)).inserted else{return}
            loweredWindows.append(WindowState(window))
            for child in window.childWindows ?? [] {collect(child)}
        }
        for source in sourceWindows {if let window=source.window {collect(window)}}
        // Do not hide or activate the whole app; let the system service's normal window appear naturally above the screenshot.
        for state in loweredWindows {state.window?.level = .normal}
        serviceChosen?()
    }
    func sharingService(_ sharingService:NSSharingService,didShareItems items:[Any]) {finish()}
    func sharingService(_ sharingService:NSSharingService,didFailToShareItems items:[Any],error:Error) {finish()}
    private func finish() {
        guard !isFinished else{return}
        isFinished=true
        // Only restore the window level without calling order-front methods; pinned screenshots hidden in the meantime retain their original floating level when shown next.
        for state in loweredWindows {state.window?.level=state.level}
        loweredWindows=[]
        if serviceStarted {activityChanged?(false)}
        try? FileManager.default.removeItem(at:directory)
        keepAlive=nil
    }
}
