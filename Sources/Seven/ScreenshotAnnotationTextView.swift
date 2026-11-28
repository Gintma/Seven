import AppKit

/// Native input replaces fallback fonts and adjusts the frame after delegate notifications; sync annotation geometry once input handling finishes.
final class ScreenshotAnnotationTextView:NSTextView {
    var inputLayoutChanged:(()->Void)?
    override func insertText(_ insertString:Any,replacementRange:NSRange) {
        // The IME commits the entire marked range; do not append confirmed text after the preedit pinyin.
        let range=replacementRange.location == NSNotFound && hasMarkedText() ? markedRange():replacementRange
        super.insertText(insertString,replacementRange:range)
        inputLayoutChanged?()
    }
    override func setMarkedText(_ string:Any,selectedRange:NSRange,replacementRange:NSRange) {
        super.setMarkedText(string,selectedRange:selectedRange,replacementRange:replacementRange)
        inputLayoutChanged?()
    }
}
