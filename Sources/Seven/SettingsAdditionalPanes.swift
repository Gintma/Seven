import SwiftUI
import AppKit

extension SettingsView {
    var screenshotPane: some View {
        SettingsForm {
            SettingsGroup(L10n.text("keyboardShortcuts")) {
                SettingsShortcutRow(title:L10n.text("screenshot"),manager:regionCaptureHotKeyManager,allManagers:allHotKeyManagers, feedback: pageFeedback,isRecording:$recordingRegionCaptureShortcut)
                SettingsShortcutRow(title:L10n.text("captureFullScreen"),manager:fullCaptureHotKeyManager,allManagers:allHotKeyManagers, feedback: pageFeedback,isRecording:$recordingFullCaptureShortcut)
                SettingsShortcutRow(title:L10n.text("capture.previousArea"),manager:previousCaptureHotKeyManager,allManagers:allHotKeyManagers, feedback: pageFeedback,isRecording:$recordingPreviousCaptureShortcut)
                SettingsShortcutRow(title:L10n.text("scrollingScreenshot"),manager:imageEntryShortcuts.scroll,allManagers:allHotKeyManagers, feedback: pageFeedback,isRecording:$recordingLongCaptureShortcut)
                SettingsShortcutRow(title:L10n.text("openLocalImage2"),manager:imageEntryShortcuts.file,allManagers:allHotKeyManagers, feedback: pageFeedback,isRecording:$recordingLocalImageShortcut)
                SettingsShortcutRow(title:L10n.text("openClipboardImage"),manager:imageEntryShortcuts.clipboard,allManagers:allHotKeyManagers, feedback: pageFeedback,isRecording:$recordingClipboardImageShortcut)
            }
            SettingsGroup(L10n.text("save")) {
                SettingsPickerRow(L10n.text("saveLocation"),selection:$screenshotSaveLocation) {ForEach(ScreenshotSaveLocation.allCases){Text($0.title).tag($0)}}
                if screenshotSaveLocation == .folder {
                    SettingsFolderRow(path:screenshotSaveFolder) {_ = chooseScreenshotSaveFolder()}
                }
                SettingsPickerRow(L10n.text("saveFormat"),selection:$screenshotSaveFormat,explanation:L10n.text("pngPreservesTransparencyJPGUsesAWhite")) {ForEach(ScreenshotSaveFormat.allCases){Text($0.title).tag($0)}}
            }
            SettingsGroup(L10n.text("shadow"),description:L10n.text("copiesAndSavedImagesIncludeTheShadow")) {
                SettingsToggleRow(L10n.text("showShadow"),isOn:$screenshotShadowEnabled)
                if screenshotShadowEnabled {
                    SettingsSliderRow(title:L10n.text("intensity"),value:$screenshotShadowOpacity,range:0...1,valueLabel:"\(Int(screenshotShadowOpacity*100))%")
                    SettingsShadowColorRow(title:L10n.text("color"),hex:$screenshotShadowColor)
                }
            }
            SettingsGroup(L10n.text("captureAids")) {
                SettingsToggleRow(L10n.text("playCaptureSound"),isOn:$screenshotCompletionSound)
                SettingsToggleRow(L10n.text("showCrosshair"),isOn:$showScreenshotCrosshair)
                SettingsToggleRow(L10n.text("showMagnifier"),isOn:$showScreenshotMagnifier)
                SettingsToggleRow(L10n.text("showScreenshotShortcuts"),isOn:$showScreenshotHints,explanation:L10n.text("showsAShortcutCardInTheLower"))
            }
            SettingsGroup(L10n.text("actions")) {
                smartSelectionToggle($smartSelectionEnabled)
                SettingsPickerRow(L10n.text("doubleClick"),selection:$screenshotDoubleClick) {ForEach(ScreenshotDoubleClickAction.allCases){Text($0.title).tag($0)}}
            }
        }.onChange(of:screenshotSaveLocation) {oldValue,newValue in
            if newValue == .folder,!chooseScreenshotSaveFolder() {screenshotSaveLocation=oldValue}
        }
    }


    @discardableResult private func chooseScreenshotSaveFolder()->Bool {
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false;panel.canCreateDirectories=true
        if !screenshotSaveFolder.isEmpty {panel.directoryURL=URL(filePath: screenshotSaveFolder, directoryHint: .checkFileSystem)}
        guard panel.runModal() == .OK,let url=panel.url else{return false}
        screenshotSaveFolder=url.fileSystemPath;return true
    }
    var toolbarPane:some View {
        SettingsForm {
            SettingsGroup(L10n.text("annotationTools")) {ForEach(ScreenshotToolbarAction.tools){action in SettingsToolbarRow(action:action,preferences:toolbarPreferences,allManagers:allHotKeyManagers,recordingAction:$recordingToolbarAction,feedback:pageFeedback)}}
            SettingsGroup(L10n.text("actions")) {ForEach(ScreenshotToolbarAction.editableOperations){action in SettingsToolbarRow(action:action,preferences:toolbarPreferences,allManagers:allHotKeyManagers,recordingAction:$recordingToolbarAction,feedback:pageFeedback)}}
            SettingsGroup(L10n.text("builtInActions")) {
                ForEach(ScreenshotToolbarAction.builtInOperations){action in SettingsToolbarRow(action:action,preferences:toolbarPreferences,allManagers:allHotKeyManagers,recordingAction:$recordingToolbarAction,feedback:pageFeedback)}
                SettingsToolbarRow(action:.drag,preferences:toolbarPreferences,allManagers:allHotKeyManagers,recordingAction:$recordingToolbarAction,feedback:pageFeedback)
            }
        }
    }

    var pinPane: some View {
        SettingsForm {
            SettingsGroup(L10n.text("defaultShadow"),description:L10n.text("changesOnlyOnScreenAppearanceCopiesAnd")) {
                SettingsToggleRow(L10n.text("showShadow"),isOn:$pinShadowEnabled)
                if pinShadowEnabled {
                    SettingsSliderRow(title:L10n.text("intensity"),value:$pinShadowOpacity,range:0...1,valueLabel:"\(Int(pinShadowOpacity*100))%")
                    SettingsShadowColorRow(title:L10n.text("color"),hex:$pinShadowColor)
                }
            }
            SettingsGroup(L10n.text("actions")) {
                SettingsShortcutRow(title:L10n.text("closePin"),manager:closePinHotKeyManager,allManagers:allHotKeyManagers, feedback: pageFeedback,isRecording:$recordingClosePinShortcut)
                SettingsShortcutRow(title:L10n.text("closeAllPins"),manager:closeAllPinsHotKeyManager,allManagers:allHotKeyManagers, feedback: pageFeedback,isRecording:$recordingCloseAllPinsShortcut)
                SettingsShortcutRow(title: L10n.text("showOrHideAllPins"), manager: pinVisibilityHotKeyManager, allManagers: allHotKeyManagers, feedback: pageFeedback, isRecording: $recordingPinVisibilityShortcut)
                SettingsPickerRow(L10n.text("zoom"), selection: $pinZoomWheel) {
                    ForEach(ScreenshotPinWheel.available(excluding: pinOpacityWheel)) { choice in Text(choice.title).tag(choice) }
                }
                SettingsPickerRow(L10n.text("opacity"), selection: $pinOpacityWheel) {
                    ForEach(ScreenshotPinWheel.available(excluding: pinZoomWheel)) { choice in Text(choice.title).tag(choice) }
                }
                SettingsShortcutRow(title: L10n.text("pinFromClipboard"), manager: clipboardPinHotKeyManager, allManagers: allHotKeyManagers, feedback: pageFeedback, isRecording: $recordingClipboardPinShortcut, explanation: L10n.text("supportsImagesAndTextImagesTakePriority"))
            }
        }
    }

    var historyPane: some View {
        SettingsForm {
            SettingsGroup {
                SettingsToggleRow(L10n.text("saveHistory"), isOn: $history.isEnabled)
                SettingsFixedPickerRow(
                    title: L10n.text("history.retention"),
                    selection: $history.retention,
                    options: HistoryRetention.allCases.map { ($0, $0.title) }
                )
                SettingsButtonRow(L10n.text("history.title")) { Button(L10n.text("open")) { model.openHistory() } }
            }
        }
    }

    var aboutPane: some View {
        SettingsForm(header: { SettingsAboutSummary() }) {
            SettingsGroup {
                SettingsButtonRow(L10n.format("version", SettingsAboutSummary.version), explanation: updateStatus) {
                    Button(L10n.text("about.checkForUpdates"), action: updater.checkForUpdates)
                        .disabled(!updater.canCheckForUpdates)
                }
                SettingsButtonRow(L10n.text("about.whatsNew")) {
                    Button(L10n.text("open")) { NSWorkspace.shared.open(updater.releaseNotesURL) }
                }
                SettingsToggleRow(L10n.text("about.updateButton"), isOn: $updater.updateButtonEnabled)
                SettingsToggleRow(L10n.text("about.automaticUpdates"), isOn: $updater.automaticUpdatesEnabled)
            }
        }
    }

    private var updateStatus: String? {
        switch updater.availability {
        case .development: return L10n.text("about.developmentUpdatesUnavailable")
        case .unconfigured: return L10n.text("about.updatesUnconfigured")
        case .supported:
            if updater.isChecking { return L10n.text("about.checkingForUpdates") }
            return nil
        }
    }
}
