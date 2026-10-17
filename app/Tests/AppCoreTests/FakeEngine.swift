// A Swift fake of the engine for the model tests: canned query answers, a scripted series of status answers, runs that
// "start" with pid 4242 and whose events the test writes, and a record of every call.
import Foundation
@testable import AppCore

struct Interrupt: Equatable, Sendable { let pid: Int32; let start: String }

actor FakeEngine: EngineClient {
    static let startTime = "Sat Oct 17 10:15:00 2026"
    var queries: [String: EngineOutput] = [:]       // keyed by the joined args
    var statusQueue: [EngineOutput] = []            // successive status --json answers; the last one stays
    var starts: [Int32: String] = [:]               // pid → its process start; a missing pid has ended
    var leaders: Set<Int32> = []
    var started: [[String]] = []
    var startedCtx: [URL] = []
    var interrupts: [Interrupt] = []
    var calls: [String] = []                        // "status", "start", "processStart", "interrupt", "run <args>"
    var onProcessStart: (@Sendable () async -> Void)?   // runs once, at the next processStart
    var gateClosed = false
    var waitingAtGate = false
    private var gate: CheckedContinuation<Void, Never>?

    func set(query args: [String], _ out: EngineOutput) { queries[args.joined(separator: " ")] = out }
    func setStatus(_ outs: [EngineOutput]) { statusQueue = outs }
    func setStarts(_ s: [Int32: String]) { starts = s }
    func setLeaders(_ l: Set<Int32>) { leaders = l }
    func setOnProcessStart(_ f: (@Sendable () async -> Void)?) { onProcessStart = f }
    func closeGate() { gateClosed = true }
    func openGate() { gateClosed = false; gate?.resume(); gate = nil }

    /// Appends lines to the events file of a ctx (default: the last started run).
    func emit(_ lines: [String], ctx: URL? = nil) {
        guard let c = ctx ?? startedCtx.last else { return }
        append(c.appending(path: "events.ndjson"), lines.map { $0 + "\n" }.joined())
    }

    func run(_ args: [String]) async throws -> EngineOutput {
        if args == ["status", "--json"] {
            calls.append("status")
            if !statusQueue.isEmpty { return statusQueue.count > 1 ? statusQueue.removeFirst() : statusQueue[0] }
        } else {
            calls.append("run " + args.joined(separator: " "))
        }
        return queries[args.joined(separator: " ")] ?? EngineOutput(stdout: Data(), stderr: "no answer", exitCode: 1)
    }

    func start(_ args: [String], ctx: URL) async throws -> Int32 {
        calls.append("start")
        if gateClosed {
            waitingAtGate = true
            await withCheckedContinuation { gate = $0 }
            waitingAtGate = false
        }
        started.append(args); startedCtx.append(ctx)
        starts[4242] = Self.startTime; leaders.insert(4242)
        return 4242
    }

    func interrupt(pid: Int32, pidStart: String) async -> Bool {
        calls.append("interrupt")
        interrupts.append(Interrupt(pid: pid, start: pidStart))
        return starts[pid] == pidStart && leaders.contains(pid)
    }

    func processStart(pid: Int32) async -> String? {
        calls.append("processStart")
        if let f = onProcessStart { onProcessStart = nil; await f() }
        return starts[pid]
    }

    func isSessionLeader(_ pid: Int32) async -> Bool { leaders.contains(pid) }
}

@MainActor final class FakeNotifier: Notifier {
    var posts: [(title: String, body: String, url: URL?)] = []
    func post(title: String, body: String, url: URL?) { posts.append((title, body, url)) }
}

enum TestDefaults {
    /// A UserDefaults of its own; remove(_) drops its domain.
    static func make() -> UserDefaults {
        let name = "AppCoreTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.set(name, forKey: "_suite")
        return d
    }
    static func remove(_ d: UserDefaults) {
        if let n = d.string(forKey: "_suite") { d.removePersistentDomain(forName: n) }
    }
}

/// A status --json answer: free, or busy with the given owner.
func statusOut(busy: Bool = false, command: String = "", runId: String = "", pid: Int32? = nil, pidStart: String = "",
               ctx: String = "", crossover: Bool = true, rosetta: Bool = true, appData: String? = nil) -> EngineOutput {
    let p = pid.map(String.init) ?? ""
    let app = appData.map { #""app":{"name":"T","version":"0.0.1","path":"/A/T.app","placement":"ok","data":"\#($0)"},"# } ?? ""
    let json = """
    {"crossover":{"found":\(crossover),"path":"/x","version":"26.3.0","supported":\(crossover)},"rosetta":\(rosetta),"msls31":true,\
    "busy":{"busy":\(busy),"command":"\(command)","run_id":"\(runId)","pid":"\(p)","pid_start":"\(pidStart)","pgid":"\(p)","ctx":"\(ctx)"},\(app)"bottles":[]}
    """
    return EngineOutput(stdout: Data(json.utf8), stderr: "", exitCode: 0)
}

let failedStatus = EngineOutput(stdout: Data(), stderr: "cannot", exitCode: 1)

/// The lines of a fixture events file.
func eventLines(_ name: String) -> [String] { text(fixture("events/\(name)")).split(separator: "\n").map(String.init) }
