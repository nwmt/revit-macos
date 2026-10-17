// The engine's events (revit --events <ctx>): one JSON object per line of <ctx>/events.ndjson, the supervisor's
// start first and its one end last. The field names are the engine's; an event this app does not know is ignored.
import Foundation

public enum EngineEvent: Equatable, Sendable {
    case start(runID: String, command: String, year: Int?, bottle: String?, pid: Int)
    case action(id: String, state: String, exit: Int?)
    case step(id: String, state: String, detail: String?)
    case progress(step: String, done: Int64, total: Int64)
    case message(level: String, text: String)
    case end(EndInfo)
    case unknown(String)                       // an event name this app does not know: ignored
}

/// The end line: the run's result, from the child's result file (revit's sup_end).
public struct EndInfo: Equatable, Sendable, Decodable {
    public let exitCode: Int
    public let result: String
    public let failedAction: String
    public let failedSteps: [String]
    public let logDir: String
    public let reason: String?                 // no_space, download: only when a downloader knew why

    public var kind: RunResult { RunResult(result) }

    public init(exitCode: Int, result: String, failedAction: String, failedSteps: [String], logDir: String, reason: String?) {
        self.exitCode = exitCode; self.result = result; self.failedAction = failedAction
        self.failedSteps = failedSteps; self.logDir = logDir; self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case exitCode = "exit_code", result, failedAction = "failed_action", failedSteps = "failed_steps", logDir = "log_dir", reason
    }
}

/// The engine's result ids (the end event's "result").
public enum RunResult: Equatable, Sendable {
    case ok, partial, failed, stopped, busy, usage, sourceMismatch, inUse, other(String)

    public init(_ raw: String) {
        switch raw {
        case "ok": self = .ok
        case "partial": self = .partial
        case "failed": self = .failed
        case "stopped": self = .stopped
        case "busy": self = .busy
        case "usage": self = .usage
        case "source_mismatch": self = .sourceMismatch
        case "in_use": self = .inUse
        default: self = .other(raw)
        }
    }
}

public enum EventParser {
    /// One line of events.ndjson → its event; nil for a line that is not a JSON object, has no "event", or lacks a key
    /// its event needs.
    public static func parse(_ line: String) -> EngineEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["event"] as? String else { return nil }
        func str(_ k: String) -> String? { obj[k] as? String }
        func int(_ k: String) -> Int? { (obj[k] as? NSNumber).flatMap { isNumber($0) ? $0.intValue : nil } }
        func int64(_ k: String) -> Int64? { (obj[k] as? NSNumber).flatMap { isNumber($0) ? $0.int64Value : nil } }
        switch name {
        case "start":
            guard let id = str("run_id"), let cmd = str("command"), let pid = int("pid") else { return nil }
            return .start(runID: id, command: cmd, year: int("year"), bottle: str("bottle"), pid: pid)
        case "action":
            guard let id = str("id"), let st = str("state") else { return nil }
            return .action(id: id, state: st, exit: int("exit"))
        case "step":
            guard let id = str("id"), let st = str("state") else { return nil }
            return .step(id: id, state: st, detail: str("detail"))
        case "progress":
            guard let step = str("step"), let done = int64("done"), let total = int64("total") else { return nil }
            return .progress(step: step, done: done, total: total)
        case "message":
            guard let level = str("level"), let text = str("text") else { return nil }
            return .message(level: level, text: text)
        case "end":
            guard let e = try? JSONDecoder().decode(EndInfo.self, from: data) else { return nil }
            return .end(e)
        default:
            return .unknown(name)
        }
    }

    // JSONSerialization gives booleans as NSNumber too: true is not the number 1 here
    private static func isNumber(_ n: NSNumber) -> Bool { CFGetTypeID(n) != CFBooleanGetTypeID() }
}
