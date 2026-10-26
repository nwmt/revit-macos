// The trackpad helper's state (spec 2026-10-26-trackpad §1): <data>/trackpad/state.json, written by the helper when it
// changes, read by the app when its menu or settings open. The app takes it only from its own session and a live helper.
import Foundation

public struct BottleState: Codable, Equatable, Sendable {
    public var ready: Bool
    public var error: String?
    public init(ready: Bool, error: String?) { self.ready = ready; self.error = error }
}

public struct HelperState: Codable, Equatable, Sendable {
    public var session: String              // the app's token for this helper
    public var pid: Int32
    public var start: String                // the helper's start time, as ps prints it
    public var trusted: Bool                // macOS lets it filter events (Accessibility)
    public var posting: Bool                // its own test event came back through its tap
    public var tap: Bool
    public var error: String?
    public var restart: String?             // why it asks the app to start it again
    public var bottles: [String: BottleState]

    public init(session: String, pid: Int32, start: String, trusted: Bool, posting: Bool, tap: Bool, error: String?,
                restart: String?, bottles: [String: BottleState]) {
        self.session = session; self.pid = pid; self.start = start; self.trusted = trusted; self.posting = posting
        self.tap = tap; self.error = error; self.restart = restart; self.bottles = bottles
    }
}

public enum StateFile {
    /// Through a temporary file beside it and a rename: a reader sees the old state or the new one, never half of one.
    public static func write(_ s: HelperState, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        try e.encode(s).write(to: tmp)
        if rename(tmp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public static func read(_ url: URL) -> HelperState? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HelperState.self, from: d)
    }
}
