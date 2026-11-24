import AppKit

/// 仅在用户点共享时创建临时 PNG，交给系统共享服务；取消或完成后删除。
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
            // 普通截图完成框选后焦点在画布；非激活工具面板的按钮点击不会自动转移焦点。
            // 共享菜单必须从键盘窗口展开，否则首次点击只显示外观，后续项目不能正常接管。
            view.window?.makeKey()
            session.picker.show(relativeTo:view.bounds,of:view,preferredEdge:.minY)
        } catch {
            let alert=NSAlert();alert.messageText=L10n.text("couldNotPrepareTheImageForSharing")
            alert.window.level=view.window?.level ?? .normal;alert.runModal()
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
        // 不隐藏、不激活整应用；让系统服务的普通窗口自然显示在截图上方。
        for state in loweredWindows {state.window?.level = .normal}
        serviceChosen?()
    }
    func sharingService(_ sharingService:NSSharingService,didShareItems items:[Any]) {finish()}
    func sharingService(_ sharingService:NSSharingService,didFailToShareItems items:[Any],error:Error) {finish()}
    private func finish() {
        guard !isFinished else{return}
        isFinished=true
        // 只恢复层级，不调用显示方法；期间被隐藏的钉图下次显示仍保持原置顶级别。
        for state in loweredWindows {state.window?.level=state.level}
        loweredWindows=[]
        if serviceStarted {activityChanged?(false)}
        try? FileManager.default.removeItem(at:directory)
        keepAlive=nil
    }
}
