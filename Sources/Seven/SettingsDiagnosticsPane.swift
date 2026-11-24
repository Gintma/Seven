#if DEBUG || SEVEN_DEVELOPMENT
import SwiftUI
import AppKit

extension SettingsView {
    var diagnosticsPane: some View {
        SettingsForm {
            SettingsGroup("滚动截图诊断") {
                SettingsToggleRow("记录滚动截图诊断", isOn: $scrollDiagnosticsEnabled,
                    explanation: "仅记录滚动方向、尺寸、匹配结果与耗时，不保存截图或页面文字。")
                SettingsButtonRow("诊断文件") {
                    Button("打开滚动截图诊断文件夹") {
                        try? FileManager.default.createDirectory(at: ScreenshotScrollTrace.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        NSWorkspace.shared.open(ScreenshotScrollTrace.directory)
                    }
                }
            }

            SettingsGroup("本地日志") {
                SettingsButtonRow("日志文件") {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([diagnostics.fileURL]) }
                }
                SettingsButtonRow("清空日志") {
                    Button("清空日志", role: .destructive) { confirmingLogClear=true }
                }
            } footer: { SettingsNote(text: "仅保存在本机 · 日志不含原文、译文或密钥") }
            SettingsGroup("记录") { SettingsLogRow(text: diagnosticText) }
            SettingsFooter("刷新", action: { Task { await refreshDiagnostics() } }) {
                EmptyView()
            }
        }
    }
    @MainActor func refreshDiagnostics() async { diagnosticText = await diagnostics.contents() }
}

private struct SettingsLogRow: View {
    let text: String
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text.isEmpty ? "暂无诊断记录" : text).font(Design.Text.code.font).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }.frame(minHeight: Design.Settings.logMinimumHeight)
    }
}
#endif
