import Foundation
import ScrollRegistrationCore

/// Retains only grayscale viewports in memory, with no extra full-size RGBA copies. Coarse thumbnails only rank candidates; the full kernel still validates final matches.
struct ScreenshotScrollReferences {
    private struct Snapshot {
        let position: Int
        let gray: [UInt8]
        let sketch: [UInt8]
    }
    private var snapshots: [Snapshot] = []
    private let width: Int
    private let height: Int
    private let sketchWidth: Int
    private let sketchHeight: Int
    private let capacity: Int
    var count: Int { snapshots.count }

    init(width: Int, height: Int) {
        self.width = min(512, width); self.height = height
        sketchWidth = min(32, width); sketchHeight = min(64, height)
        // 24MiB grayscale budget and at most 64 references; thin sparsely by position while always keeping both endpoints.
        capacity = min(64, 24 * 1024 * 1024 / max(1, self.width * height + sketchWidth * sketchHeight))
    }
    private func reduced(_ gray: [UInt8], sourceWidth: Int, targetWidth: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: targetWidth * height)
        gray.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                seven_scroll_reduce(source.baseAddress, target.baseAddress, Int32(sourceWidth), Int32(targetWidth), Int32(height))
            }
        }
        return output
    }
    private func sketch(_ gray: [UInt8]) -> [UInt8] {
        let rows = reduced(gray, sourceWidth: width, targetWidth: sketchWidth)
        var result = [UInt8](repeating: 0, count: sketchWidth * sketchHeight)
        for y in 0..<sketchHeight {
            let start = y * height / sketchHeight, end = (y + 1) * height / sketchHeight
            for x in 0..<sketchWidth {
                var sum = 0
                for row in start..<end { sum += Int(rows[row * sketchWidth + x]) }
                result[y * sketchWidth + x] = UInt8(sum / max(1, end - start))
            }
        }
        return result
    }
    mutating func remember(_ frame: ScreenshotScrollFrame, position: Int, lower: Int, upper: Int) {
        guard capacity > 0 else { return }
        guard !snapshots.contains(where: { $0.position == position }) else { return }
        let spacing = max(1, height / 4)
        if snapshots.contains(where: { abs($0.position - position) < spacing }) {
            // Track the endpoint separately to the latest position; once far enough from the previous anchor, promote the old endpoint to an intermediate reference.
            if position == upper {
                if snapshots.count > 1, snapshots[snapshots.count-1].position - snapshots[snapshots.count-2].position < spacing { snapshots.removeLast() }
            } else if position == lower {
                if snapshots.count > 1, snapshots[1].position - snapshots[0].position < spacing { snapshots.removeFirst() }
            } else { return }
        }
        let gray = reduced(frame.gray, sourceWidth: frame.width, targetWidth: width)
        snapshots.append(Snapshot(position: position, gray: gray, sketch: sketch(gray)))
        snapshots.sort { $0.position < $1.position }
        if snapshots.count > capacity {
            if capacity == 1 { snapshots.removeFirst(); return }
            let index = (1..<(snapshots.count - 1)).min {
                snapshots[$0 + 1].position - snapshots[$0 - 1].position < snapshots[$1 + 1].position - snapshots[$1 - 1].position
            }
            if let index { snapshots.remove(at: index) }
        }
    }
    func locate(_ frame: ScreenshotScrollFrame) -> (position: Int, match: SevenScrollMatch)? {
        guard !snapshots.isEmpty else { return nil }
        let gray = reduced(frame.gray, sourceWidth: frame.width, targetWidth: width)
        // Match exact revisits first so sticky headers or coarse pruning cannot pick a false offset.
        if let exact = snapshots.first(where: { $0.gray == gray }) {
            let match = SevenScrollMatch()
            return (exact.position, match)
        }
        let query = sketch(gray)
        let ranked = snapshots.map { snapshot -> (Snapshot, Float) in
            let score = snapshot.sketch.withUnsafeBufferPointer { old in
                query.withUnsafeBufferPointer { next in
                    seven_scroll_match(old.baseAddress, next.baseAddress, Int32(sketchWidth), Int32(sketchHeight)).score
                }
            }
            return (snapshot, score)
        }.sorted { $0.1 < $1.1 }
        // Thumbnails do not decide the final offset; they pick only three candidates to avoid serially scanning dozens of full-height frames on a miss.
        var best: (position: Int, match: SevenScrollMatch)?
        for (snapshot, _) in ranked.prefix(3) {
            let match = snapshot.gray.withUnsafeBufferPointer { old in
                gray.withUnsafeBufferPointer { next in
                    seven_scroll_match(old.baseAddress, next.baseAddress, Int32(width), Int32(height))
                }
            }
            // Cursor or scrollbar flicker in the same viewport can create a tiny ROI; reuse the kernel's zero-offset check,
            // so an already-captured position is not discarded merely because pixels are not byte-identical.
            guard match.status == 0 || match.status == 1 else { continue }
            if match.score < (best?.match.score ?? .greatestFiniteMagnitude) {
                best = (snapshot.position - Int(match.offset), match)
            }
        }
        return best
    }
}
