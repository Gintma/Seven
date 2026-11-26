import AppKit

/// 原生平铺分组；行由装配根提供，保持动作及快捷键所有权不变。
@MainActor enum AppStatusMenu {
    private static let updateTag = 1
    private static let updateSeparatorTag = 2

    static func refreshUpdateShortcut(in menu: NSMenu, updater: AppUpdater) {
        guard let update = menu.item(withTag: updateTag) else { return }
        update.isHidden = !updater.showsUpdateShortcut
        update.action = updater.canCheckForUpdates ? #selector(AppDelegate.checkForSevenUpdates) : nil
        menu.item(withTag: updateSeparatorTag)?.isHidden = update.isHidden
    }

    /// 使用应用动作而非系统terminate:菜单动作，避免系统自动附加退出图标。
    static func quitItem(target: NSObject?) -> NSMenuItem {
        let row = NSMenuItem(title: L10n.text("app.quit"), action: #selector(AppDelegate.quitSeven), keyEquivalent: "q")
        row.target = target; row.image = nil; row.keyEquivalentModifierMask = .command
        return row
    }
    static func build(translation: [NSMenuItem], screenshots: [NSMenuItem], ocr: [NSMenuItem], settings: NSMenuItem, updater: AppUpdater, target: NSObject?) -> NSMenu {
        let menu = NSMenu()
        let update = NSMenuItem(title: L10n.text("about.updateAvailable"), action: nil, keyEquivalent: "")
        update.target = target
        update.tag = updateTag
        menu.addItem(update)
        let updateSeparator = NSMenuItem.separator()
        updateSeparator.tag = updateSeparatorTag
        menu.addItem(updateSeparator)
        refreshUpdateShortcut(in: menu, updater: updater)
        for (index, group) in [(L10n.text("translationGroup"), translation), (L10n.text("screenshot"), screenshots), ("OCR", ocr)].enumerated() {
            let (title, rows) = group
            if index > 0 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: title))
            for row in rows { menu.addItem(row) }
        }
        menu.addItem(.separator()); menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(quitItem(target: target))
        return menu
    }
}
