import AppKit

/// 原生平铺分组；行由装配根提供，保持动作及快捷键所有权不变。
@MainActor enum AppStatusMenu {
    /// 使用应用动作而非系统terminate:菜单动作，避免系统自动附加退出图标。
    static func quitItem(target: NSObject?) -> NSMenuItem {
        let row = NSMenuItem(title: L10n.text("app.quit"), action: #selector(AppDelegate.quitSeven), keyEquivalent: "q")
        row.target = target; row.image = nil; row.keyEquivalentModifierMask = .command
        return row
    }
    static func build(translation: [NSMenuItem], screenshots: [NSMenuItem], ocr: [NSMenuItem], settings: NSMenuItem, quitTarget: NSObject? = nil) -> NSMenu {
        let menu = NSMenu()
        for (title, rows) in [(L10n.text("translationGroup"), translation), (L10n.text("screenshot"), screenshots), ("OCR", ocr)] {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: title))
            for row in rows { menu.addItem(row) }
        }
        menu.addItem(.separator()); menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(quitItem(target: quitTarget))
        return menu
    }
}
