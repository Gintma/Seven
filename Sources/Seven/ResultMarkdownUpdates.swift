import Foundation

/// Stored with a result so a completed stream can be distinguished from retained partial text.
struct MarkdownOutput: Equatable, Sendable {
    enum Status: Equatable, Sendable { case receiving, completed, interrupted }

    let requestID = UUID()
    var status: Status = .receiving
}

struct MarkdownSnapshot: Equatable, Sendable {
    let output: MarkdownOutput
    let text: String
}

struct MarkdownParseResult: Sendable {
    let document: Result<ResultMarkdownDocument, ResultMarkdownDocument.Fallback>
    let byteCount: Int
    let elapsedMilliseconds: Int
}

/// Limit concurrent parsing even when several expanded cards are receiving text.
private actor ResultMarkdownParser {
    static let shared = ResultMarkdownParser()

    func parse(_ source: String) -> MarkdownParseResult? {
        guard !Task.isCancelled else { return nil }
        let start = ContinuousClock.now
        let result: Result<ResultMarkdownDocument, ResultMarkdownDocument.Fallback>
        do {
            result = .success(try ResultMarkdownDocument.parse(source))
        } catch {
            result = .failure(error as? ResultMarkdownDocument.Fallback ?? .complexity)
        }
        let elapsed = start.duration(to: .now).components
        return MarkdownParseResult(document: result, byteCount: source.utf8.count,
                                   elapsedMilliseconds: Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000))
    }
}

@MainActor
final class ResultMarkdownUpdates {
    private let interval: Duration
    private let deliver: @MainActor (MarkdownSnapshot, MarkdownParseResult) -> Void
    private var latest: MarkdownSnapshot?
    private var lastDelivered: MarkdownSnapshot?
    private var task: Task<Void, Never>?
    private var version: UInt = 0

    init(interval: Duration = .milliseconds(250),
         deliver: @escaping @MainActor (MarkdownSnapshot, MarkdownParseResult) -> Void) {
        self.interval = interval
        self.deliver = deliver
    }

    deinit { task?.cancel() }

    func submit(_ snapshot: MarkdownSnapshot) {
        let previous = latest
        latest = snapshot
        let newRequest = previous?.output.requestID != snapshot.output.requestID
        let completed = snapshot.output.status == .completed && previous != snapshot
        if newRequest || completed { cancelTask() }
        schedule(immediately: completed)
    }

    func suspend() {
        latest = nil
        cancelTask()
    }

    func reset() {
        suspend()
        lastDelivered = nil
    }

    private func cancelTask() {
        version &+= 1
        task?.cancel()
        task = nil
    }

    private func schedule(immediately: Bool = false) {
        guard task == nil, latest != lastDelivered, latest != nil else { return }
        version &+= 1
        let version = self.version
        let delay = immediately ? Duration.zero : interval
        task = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil,
                  let snapshot = self?.latest, !Task.isCancelled else { return }
            let result = await ResultMarkdownParser.shared.parse(snapshot.text)
            // Only the live task may publish. A completion, retry or collapse cancels its predecessor.
            guard !Task.isCancelled, let self, self.version == version else { return }
            self.task = nil
            if let result {
                self.lastDelivered = snapshot
                self.deliver(snapshot, result)
            }
            self.schedule()
        }
    }
}
