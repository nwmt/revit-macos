// The app's state: the engine's status, the run it watches, the failure to show. It starts runs (each in a new folder
// under <data>/logs/runs/), follows their events, finds its own run again after a restart, and sends Cancel only to a
// run it has proved is the one it started. A run's life comes from its supervisor process, not from the lock: check
// takes none, and a child may keep the lock after the supervisor died (then the run is "finishing").
import Foundation
import Observation

public enum RunPhase: Equatable, Sendable { case running, finishing, ended, interrupted }

public struct WatchedRun: Equatable, Sendable {
    public let ctx: URL
    public var state: RunState
    public var phase: RunPhase
    public let record: RunRecord?          // non-nil: started by this app (now or before a restart)
    /// Ended well: ok, or stopped on purpose. A failure stays a failure when its details are closed.
    public var succeeded: Bool { phase == .ended && (state.end?.kind == .ok || state.end?.kind == .stopped) }
}

public enum CancelOutcome: Equatable, Sendable { case sent, refused(String) }

public enum AppModelError: Error, Equatable { case busy, noDataFolder }

@MainActor @Observable public final class AppModel {
    public private(set) var status: EngineStatus?
    public private(set) var watched: WatchedRun?
    public private(set) var failure: Failure?
    public private(set) var engineError: String?

    @ObservationIgnored let engine: any EngineClient
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let notifier: any Notifier
    @ObservationIgnored let dataOverride: URL?
    @ObservationIgnored private var reader: NDJSONReader?
    @ObservationIgnored private var supervisor: (pid: Int32, start: String)?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var lastStatus = Date.distantPast
    static let recordKey = "lastRun"

    public init(engine: any EngineClient, defaults: UserDefaults, notifier: any Notifier, dataOverride: URL? = nil) {
        self.engine = engine; self.defaults = defaults; self.notifier = notifier; self.dataOverride = dataOverride
    }

    var watchedIsActive: Bool { watched.map { $0.phase == .running || $0.phase == .finishing } ?? false }

    /// What holds the lock, while no run of the app's is being watched.
    public var busyText: String? {
        guard let s = status, s.busy.busy, !watchedIsActive else { return nil }
        return s.busy.command
    }

    public var isBusy: Bool { starting || watchedIsActive || (status?.busy.busy ?? false) }
    public var retryRequest: RunRequest? { watched?.record?.request }
    /// What Retry runs: the same request, except that an install interrupted after its bottle was made is a rebuild
    /// (the engine refuses to install into an existing bottle; Rebuild goes through its confirmation).
    public var recoveryRequest: RunRequest? {
        guard let r = retryRequest else { return nil }
        if case .interrupted = failure, case let .install(y, b, s) = r, status?.bottles.contains(where: { $0.name == b }) == true {
            return .rebuild(year: y, bottle: b, source: s)
        }
        return r
    }
    public var dataFolder: URL? { dataOverride ?? status?.app.map { URL(fileURLWithPath: $0.data) } }

    public func refresh() async { _ = await refreshed() }

    /// status --json; false when it could not be read (the old status stays).
    func refreshed() async -> Bool {
        lastStatus = Date()
        guard let out = await query(["status", "--json"]), out.exitCode == 0,
              let s = try? EngineStatus.decode(out.stdout) else { return false }
        if status != s { status = s }   // an unchanged status is no change: the open menu must not rebuild
        return true
    }

    public func query(_ args: [String]) async -> EngineOutput? {
        do { return try await engine.run(args) } catch { engineError = "\(error)"; return nil }
    }

    public func dismissFailure() { failure = nil }

    // MARK: starting

    public func start(_ r: RunRequest) async throws {
        guard !isBusy else { throw AppModelError.busy }
        starting = true            // before the first await: a second start meanwhile is refused
        defer { starting = false }
        guard let data = dataFolder else { throw AppModelError.noDataFolder }
        let ctx = data.appending(path: "logs/runs").appending(path: Self.runName())
        try FileManager.default.createDirectory(at: ctx, withIntermediateDirectories: true)
        let pid: Int32
        do { pid = try await engine.start(r.arguments, ctx: ctx) } catch { engineError = "\(error)"; throw error }
        engineError = nil
        let st = await engine.processStart(pid: pid) ?? ""
        let rec = RunRecord(ctx: ctx.path, runID: ctx.lastPathComponent, request: r, pid: pid, pidStart: st)
        if let d = try? JSONEncoder().encode(rec) { defaults.set(d, forKey: Self.recordKey) }
        failure = nil
        watch(ctx, record: rec, supervisor: (pid, st))
    }

    /// app-<yyyyMMdd-HHmmss>-<4 hex>: a new folder each time (the engine refuses one that already holds events).
    static func runName() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return "app-\(f.string(from: Date()))-\(String(format: "%04x", UInt16.random(in: .min ... .max)))"
    }

    func watch(_ ctx: URL, record: RunRecord?, supervisor sup: (Int32, String)?) {
        watched = WatchedRun(ctx: ctx, state: RunState(), phase: .running, record: record)
        reader = NDJSONReader(url: ctx.appending(path: "events.ndjson"))
        supervisor = sup.map { (pid: $0.0, start: $0.1) }
    }

    // MARK: after a restart

    public func launch() async {
        await refresh()
        let record = defaults.data(forKey: Self.recordKey).flatMap { try? JSONDecoder().decode(RunRecord.self, from: $0) }
        if let r = record, !r.pidStart.isEmpty, await engine.processStart(pid: r.pid) == r.pidStart {
            watch(URL(fileURLWithPath: r.ctx), record: r, supervisor: (r.pid, r.pidStart))   // events or not yet
            return
        }
        if let b = status?.busy, b.busy {
            let ctx = URL(fileURLWithPath: b.ctx)
            guard !b.ctx.isEmpty, FileManager.default.fileExists(atPath: ctx.appending(path: "events.ndjson").path) else { return }
            let mine = record.flatMap { $0.ctx == b.ctx && $0.runID == b.runId ? $0 : nil }
            watch(ctx, record: mine, supervisor: b.pidNumber.map { ($0, b.pidStart) })
            await poll()
            return
        }
        if let r = record {
            let ctx = URL(fileURLWithPath: r.ctx)
            var peek = NDJSONReader(url: ctx.appending(path: "events.ndjson"))
            let events = (try? peek.readNew()) ?? []
            guard !events.isEmpty, !events.contains(where: { if case .end = $0 { true } else { false } }) else { return }
            watch(ctx, record: r, supervisor: (r.pid, r.pidStart))
            await poll()
        }
    }

    // MARK: following a run

    public func poll() async { await poll(now: Date()) }

    func poll(now: Date) async {
        var refreshedNow = false
        if let w = watched, w.phase == .running || w.phase == .finishing {
            let ctx = w.ctx
            readEvents()
            if watched?.state.end != nil { await finish(); return }
            let sup = supervisor
            var alive = false
            if let s = sup, !s.start.isEmpty, s.pid > 0 { alive = await engine.processStart(pid: s.pid) == s.start }
            guard watched?.ctx == ctx else { return }
            if alive {
                if watched?.phase != .running { watched?.phase = .running }
            } else {
                // the supervisor is gone: a cached status may predate the lock, so read it now
                guard await refreshed() else { return }
                refreshedNow = true
                guard watched?.ctx == ctx else { return }
                readEvents()
                if watched?.state.end != nil { await finish(); return }
                let runID = watched?.record?.runID ?? ctx.lastPathComponent
                if let b = status?.busy, b.busy, b.runId == runID {
                    if watched?.phase != .finishing { watched?.phase = .finishing }
                } else {
                    watched?.phase = .interrupted
                    failure = .interrupted(logDir: Self.resultValue(ctx, "log_dir") ?? "")
                    defaults.removeObject(forKey: Self.recordKey)
                    post()
                }
            }
        }
        if !refreshedNow, now.timeIntervalSince(lastStatus) >= (isBusy ? 3 : 15) { await refresh() }
    }

    private func readEvents() {
        guard var r = reader, var w = watched else { return }
        let events = (try? r.readNew()) ?? []
        reader = r
        guard !events.isEmpty else { return }
        for e in events { w.state.apply(e) }
        watched = w
    }

    private func finish() async {
        guard var w = watched, let end = w.state.end else { return }
        w.phase = .ended
        watched = w
        failure = Failure.from(end: end, messages: w.state.messages, console: Self.text(w.ctx.appending(path: "console.log")), status: status)
        if w.record != nil { defaults.removeObject(forKey: Self.recordKey) }
        post()
        await refresh()
    }

    /// One notification for the end of the watched run.
    private func post() {
        guard let w = watched else { return }
        let year = w.state.year ?? w.record?.request.year
        let bottle = w.state.bottle ?? w.record?.request.bottle ?? ""
        let title = year.map { String(localized: "Revit \(String($0)) · \(bottle)") } ?? String(localized: "Revit task")
        let body: String
        switch (w.phase, w.state.end?.kind) {
        case (.interrupted, _): body = String(localized: "The task was interrupted.")
        case (_, .ok?): body = String(localized: "Done.")
        case (_, .stopped?): body = String(localized: "Stopped.")
        case (_, .partial?): body = String(localized: "Done, but some steps failed.")
        default: body = String(localized: "The task failed.")
        }
        let log = w.state.end?.logDir ?? Self.resultValue(w.ctx, "log_dir") ?? ""
        notifier.post(title: title, body: body, url: log.isEmpty ? nil : URL(fileURLWithPath: log))
    }

    // MARK: Cancel

    public func cancel() async -> CancelOutcome {
        guard await refreshed() else { return .refused(String(localized: "Could not read the engine's state.")) }
        guard let w = watched, let r = w.record else { return .refused(String(localized: "This task was not started by the app.")) }
        guard w.state.end == nil, w.phase != .ended, w.phase != .interrupted else { return .refused(String(localized: "The task has already ended.")) }
        guard w.phase == .running else { return .refused(String(localized: "The task is finishing.")) }
        guard r.request.cancellable else { return .refused(String(localized: "This task cannot be stopped.")) }
        if let b = status?.busy, b.busy, !Self.isCheck(r.request) {   // a check holds no lock: another task may hold it
            guard b.runId == r.runID, b.pidNumber == r.pid else { return .refused(String(localized: "Another task holds the lock.")) }
        }
        // the process and session checks and the signal together, after every await
        guard await engine.interrupt(pid: r.pid, pidStart: r.pidStart) else { return .refused(String(localized: "The task has already ended.")) }
        return .sent
    }

    static func isCheck(_ r: RunRequest) -> Bool { if case .check = r { true } else { false } }

    // MARK: files

    static func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// A key of <ctx>/result (key=value lines the engine writes).
    static func resultValue(_ ctx: URL, _ key: String) -> String? {
        text(ctx.appending(path: "result")).split(separator: "\n").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }
}
