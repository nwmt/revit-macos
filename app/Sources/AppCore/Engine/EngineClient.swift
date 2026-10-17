// How the app talks to the engine (revit): short queries that it waits for, long runs that it starts and watches
// through their events, and Cancel. The models use only this protocol, so the tests can give them a fake.
import Foundation

public struct EngineOutput: Sendable, Equatable {
    public let stdout: Data
    public let stderr: String
    public let exitCode: Int32
    public init(stdout: Data, stderr: String, exitCode: Int32) { self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode }
}

public protocol EngineClient: Sendable {
    /// A short command (status --json, find-installer, a dry run…): waits for it. A non-zero exit is a normal output
    /// (report's refusal is JSON on stdout with exit 1); throws only when it cannot start.
    func run(_ args: [String]) async throws -> EngineOutput
    /// A long command with ["--events", ctx.path] appended, in a session of its own; returns its pid. ctx must exist.
    func start(_ args: [String], ctx: URL) async throws -> Int32
    /// Cancel: right before the signal, in one go, the pid must be > 1, pidStart non-empty and equal to its
    /// `ps -o lstart=`, and the process the leader of its session and group; then INT to its group. True when sent.
    func interrupt(pid: Int32, pidStart: String) async -> Bool
    /// `ps -o lstart= -p <pid>`, trimmed; nil when the process is gone or pid ≤ 0.
    func processStart(pid: Int32) async -> String?
    /// pid > 1 and the process leads its session and its group (what start makes).
    func isSessionLeader(_ pid: Int32) async -> Bool
}

/// The environment of every engine process: the user's HOME, USER, LOGNAME, TMPDIR, a plain PATH, UTF-8, and the
/// app's own REVIT_DATA, REVIT_LOCK_DIR, REVIT_CX and FAKE_* when set (dev, the demo); nothing else.
public enum EngineEnvironment {
    public static func make(from env: [String: String]) -> [String: String] {
        var out: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        for k in ["HOME", "USER", "LOGNAME", "TMPDIR", "REVIT_DATA", "REVIT_LOCK_DIR", "REVIT_CX"] { if let v = env[k] { out[k] = v } }
        for (k, v) in env where k.hasPrefix("FAKE_") { out[k] = v }
        return out
    }
}
