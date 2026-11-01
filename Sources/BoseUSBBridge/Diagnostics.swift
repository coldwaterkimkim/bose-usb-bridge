import Foundation

/// Main-queue snapshots. Coalesces bursts and never rewrites unchanged data.
final class Diagnostics {
    private let url: URL
    private let formatter = ISO8601DateFormatter()
    private var events: [[String: String]] = []
    private var pending: DispatchWorkItem?
    private var previousData: Data?

    init(url: URL) { self.url = url }

    func record(_ event: String) {
        events.append(["time": formatter.string(from: Date()), "event": event])
        if events.count > 100 { events.removeFirst(events.count - 100) }
    }

    func schedule(snapshot: @escaping () -> [String: Any]) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.write(snapshot())
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @discardableResult
    func write(_ snapshot: [String: Any]) -> Bool {
        pending?.cancel(); pending = nil
        var content = snapshot
        content["events"] = events
        guard let data = try? JSONSerialization.data(withJSONObject: content, options: [.prettyPrinted, .sortedKeys]),
              data != previousData else { return false }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            previousData = data
            return true
        } catch { return false }
    }

    deinit { pending?.cancel() }
}
