// The trackpad helper's log, <data>/logs/trackpad.log (spec §9): one line each, a time first; past the limit the file
// becomes trackpad.log.1 (the one before is replaced). Never window titles, coordinates or paths of this Mac: the
// callers write classes of windows, decisions, bottles and failures only. Written on a queue of its own, so no caller
// (the event tap's thread least of all) waits for the disk.
import Foundation

public final class TrackpadLog: Sendable {
    let url: URL, limit: Int
    private let queue = DispatchQueue(label: "trackpad.log")
    nonisolated(unsafe) private var lastChange = ""   // only on the queue

    public init(url: URL, limit: Int = 1_000_000) { self.url = url; self.limit = limit }

    public func line(_ s: String) {
        let now = Date()
        queue.async { self.append(now, s) }
    }

    /// A line that may come with every gesture: written only when it differs from the last one given this way. An
    /// empty one writes nothing and forgets the last.
    public func lineOnChange(_ s: String) {
        let now = Date()
        queue.async {
            guard s != self.lastChange else { return }
            self.lastChange = s
            if !s.isEmpty { self.append(now, s) }
        }
    }

    /// Waits until every line given so far is written (tests, and before the helper exits).
    public func flush() { queue.sync {} }

    private func append(_ when: Date, _ s: String) {
        let text = Data((ISO8601DateFormatter().string(from: when) + " " + s + "\n").utf8)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 0 && size + text.count > limit {
            let old = url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(text); try? h.close()
        } else {
            try? text.write(to: url)
        }
    }
}
