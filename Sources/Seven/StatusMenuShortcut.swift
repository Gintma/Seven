import AppKit
import Carbon

/// Status menu uses the native trailing shortcut column instead of concatenating shortcuts into titles.
@MainActor enum StatusMenuShortcut {
    static func apply(_ shortcut:KeyboardShortcut?,to item:NSMenuItem) {
        guard let shortcut else{item.keyEquivalent="";item.keyEquivalentModifierMask=[];return}
        let special:[UInt32:UInt16]=[
            UInt32(kVK_Return):13,UInt32(kVK_Space):32,UInt32(kVK_Tab):9,UInt32(kVK_Delete):8,UInt32(kVK_Escape):27,
            UInt32(kVK_ForwardDelete):UInt16(NSDeleteFunctionKey),UInt32(kVK_LeftArrow):UInt16(NSLeftArrowFunctionKey),
            UInt32(kVK_RightArrow):UInt16(NSRightArrowFunctionKey),UInt32(kVK_UpArrow):UInt16(NSUpArrowFunctionKey),UInt32(kVK_DownArrow):UInt16(NSDownArrowFunctionKey),
            UInt32(kVK_Home):UInt16(NSHomeFunctionKey),UInt32(kVK_End):UInt16(NSEndFunctionKey),
            UInt32(kVK_PageUp):UInt16(NSPageUpFunctionKey),UInt32(kVK_PageDown):UInt16(NSPageDownFunctionKey)
        ]
        let functionCodes=[kVK_F1,kVK_F2,kVK_F3,kVK_F4,kVK_F5,kVK_F6,kVK_F7,kVK_F8,kVK_F9,kVK_F10,kVK_F11,kVK_F12].map(UInt32.init)
        if let value=special[shortcut.keyCode],let scalar=UnicodeScalar(value) {item.keyEquivalent=String(scalar)}
        else if let index=functionCodes.firstIndex(of:shortcut.keyCode),let scalar=UnicodeScalar(UInt32(NSF1FunctionKey)+UInt32(index)) {item.keyEquivalent=String(scalar)}
        else {item.keyEquivalent=shortcut.keyLabel.lowercased()}
        var modifiers:NSEvent.ModifierFlags=[]
        if shortcut.carbonModifiers & UInt32(cmdKey) != 0 {modifiers.insert(.command)}
        if shortcut.carbonModifiers & UInt32(optionKey) != 0 {modifiers.insert(.option)}
        if shortcut.carbonModifiers & UInt32(controlKey) != 0 {modifiers.insert(.control)}
        if shortcut.carbonModifiers & UInt32(shiftKey) != 0 {modifiers.insert(.shift)}
        item.keyEquivalentModifierMask=modifiers
    }
}
