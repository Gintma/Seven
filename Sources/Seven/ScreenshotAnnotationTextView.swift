import AppKit

/// 原生输入会在 delegate 通知之后替换回退字体并调整 frame；完成输入处理后再同步标注几何。
final class ScreenshotAnnotationTextView:NSTextView {
    var inputLayoutChanged:(()->Void)?
    override func insertText(_ insertString:Any,replacementRange:NSRange) {
        // 输入法提交的是整个组合区；不能把确认文字追加在拼音后面。
        let range=replacementRange.location == NSNotFound && hasMarkedText() ? markedRange():replacementRange
        super.insertText(insertString,replacementRange:range)
        inputLayoutChanged?()
    }
    override func setMarkedText(_ string:Any,selectedRange:NSRange,replacementRange:NSRange) {
        super.setMarkedText(string,selectedRange:selectedRange,replacementRange:replacementRange)
        inputLayoutChanged?()
    }
}
