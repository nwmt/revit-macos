// The trackpad helper's arguments: the app passes them when it starts the helper (NSWorkspace.OpenConfiguration).
import Foundation

public struct HelperArgs: Equatable, Sendable {
    public var session: String
    public var parentPid: Int32             // the app: the helper ends when this process (with this start time) is gone
    public var parentStart: String
    public var engine: URL                  // the revit script it runs for status --json and hittest
    public var data: URL                    // the app's data folder: trackpad/state.json, logs/trackpad.log
    public var recover: Bool                // the last helper ended unexpectedly: release the middle button first
    public var recoverOnly: Bool            // only that, then exit (the switch is off)

    public init(session: String, parentPid: Int32, parentStart: String, engine: URL, data: URL, recover: Bool,
                recoverOnly: Bool) {
        self.session = session; self.parentPid = parentPid; self.parentStart = parentStart; self.engine = engine
        self.data = data; self.recover = recover; self.recoverOnly = recoverOnly
    }

    public func argv() -> [String] {
        var a = ["--session", session, "--parent", "\(parentPid):\(parentStart)", "--engine", engine.path, "--data", data.path]
        if recover { a.append("--recover") }
        if recoverOnly { a.append("--recover-only") }
        return a
    }

    /// nil for anything else than argv() makes: a missing value, an unknown word, no session.
    public static func parse(_ argv: [String]) -> HelperArgs? {
        var session: String?, parent: String?, engine: String?, data: String?, recover = false, recoverOnly = false
        var i = 0
        while i < argv.count {
            let a = argv[i]
            switch a {
            case "--recover": recover = true
            case "--recover-only": recoverOnly = true
            case "--session", "--parent", "--engine", "--data":
                guard i + 1 < argv.count else { return nil }
                let v = argv[i + 1]; i += 1
                switch a { case "--session": session = v; case "--parent": parent = v; case "--engine": engine = v; default: data = v }
            default: return nil
            }
            i += 1
        }
        guard let session, !session.isEmpty, let parent, let engine, let data,
              let colon = parent.firstIndex(of: ":"), let pid = Int32(parent[..<colon]) else { return nil }
        return HelperArgs(session: session, parentPid: pid, parentStart: String(parent[parent.index(after: colon)...]),
                          engine: URL(fileURLWithPath: engine), data: URL(fileURLWithPath: data), recover: recover,
                          recoverOnly: recoverOnly)
    }
}
