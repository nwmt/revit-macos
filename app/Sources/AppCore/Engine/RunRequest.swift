// A run the app asks the engine for, and what the app remembers about a run it started (kept across restarts, so
// after a relaunch it still knows the run as its own: Retry, the source choice, Cancel).
import Foundation

/// The answer to "the unpacked installer is from another installer": --reuse-extracted or --reextract.
public enum SourceChoice: String, Codable, Equatable, Sendable { case reuseExtracted, reextract }

public enum RunRequest: Codable, Equatable, Sendable {
    case install(year: Int, bottle: String, source: SourceChoice?)
    case rebuild(year: Int, bottle: String, source: SourceChoice?)
    case check(year: Int, bottle: String, source: SourceChoice?)
    case addins(year: Int, bottle: String, ids: [String], eula: [String])
    case remove(year: Int, bottle: String)
    case stop(year: Int, bottle: String)

    /// The engine's argv, without --events.
    public var arguments: [String] {
        func flag(_ s: SourceChoice?) -> [String] {
            switch s { case .reuseExtracted?: ["--reuse-extracted"]; case .reextract?: ["--reextract"]; case nil: [] }
        }
        switch self {
        case let .install(y, b, s): return ["install", String(y), b, "--yes"] + flag(s)
        case let .rebuild(y, b, s): return ["rebuild", String(y), b, "--yes"] + flag(s)
        case let .check(y, b, s): return ["check", String(y), b] + flag(s)
        case let .addins(y, b, ids, eula):
            return ["addins", String(y), b, "--only", ids.joined(separator: ",")] + (eula.isEmpty ? [] : ["--accept-eula", eula.joined(separator: ",")])
        case let .remove(y, b): return ["remove", String(y), b, "--yes"]
        case let .stop(y, b): return ["stop", String(y), b]
        }
    }

    /// The supervised commands, which end as stopped on INT.
    public var cancellable: Bool {
        switch self { case .install, .rebuild, .check, .addins: true; case .remove, .stop: false }
    }

    /// install, rebuild and check with that source flag; the others as they are.
    public func with(_ source: SourceChoice) -> RunRequest {
        switch self {
        case let .install(y, b, _): .install(year: y, bottle: b, source: source)
        case let .rebuild(y, b, _): .rebuild(year: y, bottle: b, source: source)
        case let .check(y, b, _): .check(year: y, bottle: b, source: source)
        default: self
        }
    }

    public var year: Int {
        switch self {
        case let .install(y, _, _), let .rebuild(y, _, _), let .check(y, _, _), let .addins(y, _, _, _), let .remove(y, _), let .stop(y, _): y
        }
    }

    public var bottle: String {
        switch self {
        case let .install(_, b, _), let .rebuild(_, b, _), let .check(_, b, _), let .addins(_, b, _, _), let .remove(_, b), let .stop(_, b): b
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
