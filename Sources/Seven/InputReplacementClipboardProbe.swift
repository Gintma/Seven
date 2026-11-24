import AppKit

/// 以两次稳定的原生复制结果为正文，AX 只独立核验目标；不跨格式比较字符串。
@MainActor
enum InputReplacementClipboardProbe {
    private static var isBusy = false

    @discardableResult
    static func verify(
        pasteboard: NSPasteboard = .general,
        copy: () throws -> Void,
        checkTarget: () throws -> Void,
        attempts: Int = 30,
        pause: () async -> Void = {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { continuation.resume() }
            }
        }
    ) async throws -> String {
        guard !isBusy else { throw InputReplacementError.unreadable }
        try Task.checkCancellation()
        try checkTarget()
        isBusy = true
        let saved = PasteboardSnapshot.capture(from: pasteboard)
        var ownedCount = pasteboard.changeCount
        defer {
            _ = saved.restore(to: pasteboard, ifUnchangedSince: ownedCount)
            isBusy = false
        }
        var firstCopy: String?
        var firstWasEmpty = false
        for _ in 0..<2 {
            try Task.checkCancellation()
            try checkTarget()
            pasteboard.clearContents()
            let clearedCount = pasteboard.changeCount
            ownedCount = clearedCount
            try copy()
            var copied: String?
            var copiedCount = clearedCount
            for _ in 0..<attempts {
                // 原生复制已投递时让短租约完成，再响应取消，防止迟到复制覆盖恢复内容。
                await pause()
                if pasteboard.changeCount != clearedCount {
                    copiedCount = pasteboard.changeCount
                    copied = pasteboard.string(forType: .string)
                    break
                }
            }
            try checkTarget()
            let noText = copied?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            if noText {
                if firstCopy != nil { throw InputReplacementError.contentChanged }
                ownedCount = copiedCount
                try Task.checkCancellation()
                if firstWasEmpty { throw InputReplacementError.empty }
                firstWasEmpty = true
                continue
            }
            guard let copied else { throw InputReplacementError.unreadable }
            if firstWasEmpty { throw InputReplacementError.contentChanged }
            if let firstCopy {
                guard copied == firstCopy else { throw InputReplacementError.contentChanged }
                ownedCount = copiedCount
                try Task.checkCancellation()
                return copied
            }
            // 只有当前目标仍有效时才保存本次副本；下一轮再次复制验证稳定性。
            firstCopy = copied
            ownedCount = copiedCount
            try Task.checkCancellation()
        }
        throw InputReplacementError.unreadable
    }
}
