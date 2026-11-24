import AppKit

/// 直接使用系统截图音，不复制系统音频资源到仓库；播放仍由用户的成功提示音开关控制。
@MainActor enum ScreenshotCompletionSound {
    static let fileURL=URL(filePath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", directoryHint: .checkFileSystem)
    private static let sound=NSSound(contentsOf:fileURL,byReference:true)
    static func play() {_ = sound?.play()}
}
