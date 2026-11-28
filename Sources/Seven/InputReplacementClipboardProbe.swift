import AppKit

/// Uses two stable native copy reads as the source text while AX independently verifies the target; never compares strings across formats.
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
                // Once native copy is posted, let the short lease finish before honoring cancellation so a late copy cannot overwrite restored clipboard contents.
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
            // Save this copy only while the target remains valid; the next pass copies again to verify stability.
            firstCopy = copied
            ownedCount = copiedCount
            try Task.checkCancellation()
        }
        throw InputReplacementError.unreadable
    }
}
