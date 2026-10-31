// A run the app asks the engine for, and what the app remembers about a run it started (kept across restarts, so
// after a relaunch it still knows the run as its own: Retry, the source choice, Cancel).
import Foundation

/// The answer to "the unpacked installer is from another installer": --reuse-extracted or --reextract.
public enum SourceChoice: String, Codable, Equatable, Sendable { case reuseExtracted, reextract }

public enum RunRequest: Codable, Equatable, Sendable {
    case install(year: Int, bottle: String, source: SourceChoice?)
    case rebuild(year: Int, bottle: String, source: SourceChoice?, noPoint: Bool? = nil)   // nil in a request saved by an older app
    case check(year: Int, bottle: String, source: SourceChoice?)
    case addins(year: Int, bottle: String, ids: [String], eula: [String])
    case remove(year: Int, bottle: String)
    case stop(year: Int, bottle: String)
    case set(year: Int, bottle: String, settings: [String])
    case update(year: Int, bottle: String, from: String, noPoint: Bool? = nil)
    case rollback(year: Int, bottle: String, id: String)
    case clearPoints(year: Int, bottle: String, ids: [String], clearUnfinished: Bool)

    /// A rebuild as the person confirmed it: without a restore point only when the sheet showed that.
    public func keeping(point: Bool) -> RunRequest {
        switch self {
        case let .rebuild(y, b, s, _): .rebuild(year: y, bottle: b, source: s, noPoint: point ? nil : true)
        case let .update(y, b, f, _): .update(year: y, bottle: b, from: f, noPoint: point ? nil : true)
        default: self
        }
    }

    /// Deletes or replaces something: Retry goes through its sheet and a new plan, never straight to the engine.
    public var needsSheet: Bool {
        switch self { case .remove, .rebuild, .update, .rollback, .clearPoints: true; default: false }
    }

    /// What may be written down: a Google account's address stays in memory.
    public var persistable: RunRequest {
        switch self {
        case let .set(y, b, s): .set(year: y, bottle: b, settings: s.map { $0.hasPrefix("gdrive=") && $0.contains("@") ? Self.accountMark : $0 })
        case let .update(y, b, f, np) where f.contains("@"): .update(year: y, bottle: b, from: "", noPoint: np)   // GoogleDrive-<address>
        default: self
        }
    }

    static let accountMark = "gdrive=account"

    /// Came back from disk without its address: it cannot run again.
    public var lostAddress: Bool {
        switch self {
        case let .set(_, _, s): s.contains(Self.accountMark)
        case let .update(_, _, f, _): f.isEmpty
        default: false
        }
    }

    /// The engine's argv, without --events.
    public var arguments: [String] {
        func flag(_ s: SourceChoice?) -> [String] {
            switch s { case .reuseExtracted?: ["--reuse-extracted"]; case .reextract?: ["--reextract"]; case nil: [] }
        }
        switch self {
        case let .install(y, b, s): return ["install", String(y), b, "--yes"] + flag(s)
        case let .rebuild(y, b, s, np): return ["rebuild", String(y), b, "--yes"] + flag(s) + (np == true ? ["--no-point"] : [])
        case let .check(y, b, s): return ["check", String(y), b] + flag(s)
        case let .addins(y, b, ids, eula):
            return ["addins", String(y), b, "--only", ids.joined(separator: ",")] + (eula.isEmpty ? [] : ["--accept-eula", eula.joined(separator: ",")])
        case let .remove(y, b): return ["remove", String(y), b, "--yes"]
        case let .stop(y, b): return ["stop", String(y), b]
        case let .set(y, b, s): return ["set", String(y), b] + s
        case let .update(y, b, f, np): return ["update", String(y), b, "--yes", "--from", f] + (np == true ? ["--no-point"] : [])
        case let .rollback(y, b, id): return ["rollback", String(y), b, "--yes", "--to", id]
        case let .clearPoints(y, b, ids, left):
            return ["points", String(y), b, "--yes"] + (ids.isEmpty ? [] : ["--clear-ids", ids.joined(separator: ",")]) + (left ? ["--clear-unfinished"] : [])
        }
    }

    /// What a sheet reads before it asks: only remove, rebuild and update have this plan.
    public var planArguments: [String] {
        var a = [arguments[0], String(year), bottle]
        if case let .update(_, _, f, _) = self { a += ["--from", f] }
        return a + ["--dry-run", "--json"]
    }

    /// The supervised commands, which end as stopped on INT.
    public var cancellable: Bool {
        switch self { case .install, .rebuild, .update, .check, .addins: true; case .remove, .stop, .set, .rollback, .clearPoints: false }
    }

    /// install, rebuild and check with that source flag; the others as they are.
    public func with(_ source: SourceChoice) -> RunRequest {
        switch self {
        case let .install(y, b, _): .install(year: y, bottle: b, source: source)
        case let .rebuild(y, b, _, np): .rebuild(year: y, bottle: b, source: source, noPoint: np)
        case let .check(y, b, _): .check(year: y, bottle: b, source: source)
        default: self
        }
    }

    public var year: Int {
        switch self {
        case let .install(y, _, _), let .rebuild(y, _, _, _), let .update(y, _, _, _), let .check(y, _, _), let .addins(y, _, _, _), let .remove(y, _), let .stop(y, _),
             let .set(y, _, _), let .rollback(y, _, _), let .clearPoints(y, _, _, _): y
        }
    }

    public var bottle: String {
        switch self {
        case let .install(_, b, _), let .rebuild(_, b, _, _), let .update(_, b, _, _), let .check(_, b, _), let .addins(_, b, _, _), let .remove(_, b), let .stop(_, b),
             let .set(_, b, _), let .rollback(_, b, _), let .clearPoints(_, b, _, _): b
        }
    }
}

/// A run this app started: its folder (whose name is the engine's run_id), what it asked for, and the process the
/// engine runs in, with its start time (a reused pid has another).
public struct RunRecord: Codable, Equatable, Sendable {
    public let ctx: String
    public let runID: String
    public let request: RunRequest
    public let pid: Int32
    public let pidStart: String

    public init(ctx: String, runID: String, request: RunRequest, pid: Int32, pidStart: String) {
        self.ctx = ctx; self.runID = runID; self.request = request; self.pid = pid; self.pidStart = pidStart
    }
}
