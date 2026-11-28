import AppKit

/// Plays the system screenshot sound directly without bundling system audio assets; still gated by the user's completion-sound preference.
@MainActor enum ScreenshotCompletionSound {
    static let fileURL=URL(filePath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", directoryHint: .checkFileSystem)
    private static let sound=NSSound(contentsOf:fileURL,byReference:true)
    static func play() {_ = sound?.play()}
}
