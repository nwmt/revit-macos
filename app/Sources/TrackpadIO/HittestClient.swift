// The client of one bottle's hittest (spec 2026-10-26-trackpad §4): runs "revit hittest <year> <bottle>" in a process
// group of its own, reads its lines on a thread of its own, and answers query() from the event tap's thread within a
// deadline. Every state lives under one lock; each process is a generation, and an answer counts only for the
// generation and the request it belongs to. A process that misbehaves is ended and started again, at most every
// timing.restart seconds; three failures in a row: failed. Exit 75 ("try again later": the engine is busy) is no
// failure. After stop() nothing starts again.
import CoreGraphics
import Darwin
import Foundation
import TrackpadCore

public enum ClientStatus: Equatable, Sendable {
    case starting, ready(scale: Int), notReady(String), retryLater, failed(String), stopped
}

public struct ClientTiming: Sendable {
    public var hello, reply, restart, termGrace: Double
    public init(hello: Double = TrackpadConstants.helloTimeout, reply: Double = TrackpadConstants.hitTimeout,
                restart: Double = TrackpadConstants.restartInterval, termGrace: Double = 2) {
        self.hello = hello; self.reply = reply; self.restart = restart; self.termGrace = termGrace
    }
}

/// What the decision on the tap's thread needs from a client (a fake in the tests).
public protocol HitQuerying: AnyObject, Sendable {
    var status: ClientStatus { get }
    func query(_ p: WinePoint) -> HitReply?
}

public final class HittestClient: HitQuerying, @unchecked Sendable {
    private let engine: URL, year: Int, bottle: String, environment: [String: String], log: TrackpadLog
    private let scale: @Sendable (CGRect) -> Int?, timing: ClientTiming
    private let cond = NSCondition()
    // under cond
    private var state = ClientStatus.stopped
    private var stopped = true, restartNow = false
    private var generation = 0
    private var pid: pid_t = 0, input: Int32 = -1
    private var live = Set<pid_t>()             // started and not reaped yet: only these groups may be signalled
    private var seq = 0, outstanding: Int?, answer: HitReply?
    private var misses = 0, failures = 0
    private var ended = false                   // this generation was ended by us (transport failure, restart)
    private var layout = false                  // this generation's hello did not fit the screens

    public init(engine: URL, year: Int, bottle: String, environment: [String: String], log: TrackpadLog,
                scale: @escaping @Sendable (CGRect) -> Int?, timing: ClientTiming = ClientTiming()) {
        self.engine = engine; self.year = year; self.bottle = bottle; self.environment = environment; self.log = log
        self.scale = scale; self.timing = timing
    }

    public var status: ClientStatus { cond.lock(); defer { cond.unlock() }; return state }

    public func start() {
        cond.lock()
        guard stopped else { cond.unlock(); return }
        stopped = false; failures = 0
        cond.unlock()
        Thread.detachNewThread { self.supervise() }
    }

    /// A new process now (the screens changed): the failure count starts over.
    public func restart() {
        cond.lock()
        guard !stopped else { cond.unlock(); return }
        restartNow = true; failures = 0
        let gen = generation
        cond.broadcast()
        cond.unlock()
        end(gen, "restart")
    }

    public func stop() {
        cond.lock()
        stopped = true; generation += 1; state = .stopped
        let fd = input, p = pid
        input = -1
        cond.broadcast()
        cond.unlock()
        if fd >= 0 { close(fd) }
        if p > 0 { terminateLater(p) }
        log.line("hittest \(bottle): stopped")
    }

    public func query(_ p: WinePoint) -> HitReply? {
        cond.lock()
        guard case .ready = state, input >= 0, outstanding == nil else { cond.unlock(); return nil }
        seq += 1
        let my = seq, gen = generation, fd = dup(input)
        outstanding = my; answer = nil
        cond.unlock()
        let start = DispatchTime.now().uptimeNanoseconds
        let line = Array(HittestProtocol.request(seq: my, x: p.x, y: p.y).utf8)
        var wrote = -1
        if fd >= 0 { _ = fcntl(fd, F_SETNOSIGPIPE, 1); wrote = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }; close(fd) }
        if wrote != line.count {
            cond.lock(); if outstanding == my { outstanding = nil }; cond.unlock()
            end(gen, "cannot write")
            return nil
        }
        cond.lock()
        while answer == nil && generation == gen && !stopped {
            let left = timing.reply - Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            if left <= 0 { break }
            _ = cond.wait(until: Date(timeIntervalSinceNow: left))
        }
        let r = generation == gen ? answer : nil
        outstanding = nil; answer = nil
        var fail = false
        if r != nil { misses = 0; failures = 0 } else if generation == gen && !stopped { misses += 1; fail = misses >= 2 }
        cond.unlock()
        if fail { end(gen, "no answer twice") }
        return r
    }

    // MARK: the process

    private func supervise() {
        while true {
            cond.lock()
            if stopped { cond.unlock(); return }
            generation += 1
            let gen = generation
            state = .starting; ended = false; layout = false; misses = 0; outstanding = nil; answer = nil; restartNow = false
            cond.unlock()

            var code: Int32 = -1
            if let (p, inFD, outFD) = spawn() {
                cond.lock()
                live.insert(p)
                let current = generation == gen
                if current { pid = p; input = inFD }
                cond.unlock()
                if !current { close(inFD) }
                let reader = Thread { self.read(outFD, gen) }
                reader.start()
                DispatchQueue.global().asyncAfter(deadline: .now() + timing.hello) { self.helloDeadline(gen) }
                var st: Int32 = 0
                while waitpid(p, &st, 0) == -1 && errno == EINTR {}
                code = (st & 0x7f) == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f)
                kill(-p, SIGTERM)                       // what it left behind in its group
                cond.lock()
                live.remove(p)
                if generation == gen { pid = 0; if input >= 0 { close(input); input = -1 } }
                cond.unlock()
            }

            cond.lock()
            if stopped { cond.unlock(); return }
            var delay = timing.restart
            if restartNow {
                delay = 0
            } else if layout {
                state = .notReady("unknown display layout")
                delay = .infinity                       // until restart() (the screens changed) or stop()
            } else if code == 75 {
                state = .retryLater
            } else {
                failures += 1
                if failures >= TrackpadConstants.failuresToError {
                    state = .failed("hittest ended \(failures) times in a row")
                    delay = .infinity
                } else if case .notReady = state {} else {
                    state = .notReady("hittest ended (exit \(code))")
                }
            }
            let why = state
            cond.unlock()
            log.line("hittest \(bottle): exit \(code), \(describe(why))")
            cond.lock()
            let until = Date(timeIntervalSinceNow: min(delay, 1e9))
            while !stopped && !restartNow && Date() < until { _ = cond.wait(until: until) }
            cond.unlock()
        }
    }

    private func describe(_ s: ClientStatus) -> String {
        switch s {
        case .retryLater: return "later"
        case .failed(let w): return "failed: \(w)"
        case .notReady(let w): return w
        default: return "\(s)"
        }
    }

    private func read(_ fd: Int32, _ gen: Int) {
        var buf = LineBuffer(), hello = false
        var chunk = [UInt8](repeating: 0, count: 4096)
        defer { close(fd) }
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { end(gen, "end of output"); return }
            for ev in buf.append(Data(chunk[0..<n])) {
                guard case .line(let l) = ev else { end(gen, "line too long"); return }
                if !hello {
                    guard let rect = HittestProtocol.hello(l) else { end(gen, "no hello"); return }
                    hello = true
                    let s = scale(rect)
                    cond.lock()
                    guard generation == gen else { cond.unlock(); return }
                    if let s { state = .ready(scale: s) } else { layout = true }
                    cond.unlock()
                    log.line("hittest \(bottle): \(s.map { "ready, scale \($0)" } ?? "unknown display layout")")
                    if s == nil { end(gen, "unknown display layout"); return }
                    continue
                }
                guard let r = HittestProtocol.reply(l) else { end(gen, "bad answer"); return }
                cond.lock()
                if generation == gen, r.seq == outstanding { answer = r; cond.broadcast() }
                cond.unlock()
            }
        }
    }

    private func helloDeadline(_ gen: Int) {
        cond.lock()
        let late = generation == gen && state == .starting
        cond.unlock()
        if late { end(gen, "no hello") }
    }

    /// Ends this generation's process: input closed, then TERM to its group after timing.termGrace.
    private func end(_ gen: Int, _ why: String) {
        cond.lock()
        guard generation == gen, !ended else { cond.unlock(); return }
        ended = true
        if case .ready = state { state = .notReady(why) } else if state == .starting { state = .notReady(why) }
        let fd = input, p = pid
        input = -1
        cond.broadcast()
        cond.unlock()
        if why != "end of output" && why != "restart" { log.line("hittest \(bottle): \(why)") }
        if fd >= 0 { close(fd) }
        if p > 0 { terminateLater(p) }
    }

    private func terminateLater(_ p: pid_t) {
        DispatchQueue.global().asyncAfter(deadline: .now() + timing.termGrace) {
            self.cond.lock()
            let mine = self.live.contains(p)
            self.cond.unlock()
            if mine { kill(-p, SIGTERM) }
        }
    }

    /// /bin/bash <engine> hittest <year> <bottle> in a new process group: stdin and stdout are pipes to us, stderr
    /// /dev/null (its messages name paths of this Mac; the exit code says enough). No other descriptor of ours.
    private func spawn() -> (pid_t, Int32, Int32)? {
        var inP: [Int32] = [-1, -1], outP: [Int32] = [-1, -1]
        guard pipe(&inP) == 0 else { return nil }
        guard pipe(&outP) == 0 else { close(inP[0]); close(inP[1]); return nil }
        var attr: posix_spawnattr_t? = nil, fa: posix_spawn_file_actions_t? = nil
        posix_spawnattr_init(&attr); defer { posix_spawnattr_destroy(&attr) }
        posix_spawn_file_actions_init(&fa); defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var def = sigset_t(); sigemptyset(&def)
        for s in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&def, s) }
        posix_spawnattr_setsigdefault(&attr, &def)
        var mask = sigset_t(); sigemptyset(&mask); posix_spawnattr_setsigmask(&attr, &mask)
        posix_spawn_file_actions_adddup2(&fa, inP[0], 0)
        posix_spawn_file_actions_adddup2(&fa, outP[1], 1)
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        let argv = ["/bin/bash", engine.path, "hittest", String(year), bottle]
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnvp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in cArgv { free(p) }; for p in cEnvp { free(p) } }
        var p: pid_t = 0
        let rc = posix_spawn(&p, "/bin/bash", &fa, &attr, &cArgv, &cEnvp)
        close(inP[0]); close(outP[1])
        guard rc == 0 else { close(inP[1]); close(outP[0]); return nil }
        _ = fcntl(inP[1], F_SETFL, O_NONBLOCK); _ = fcntl(inP[1], F_SETNOSIGPIPE, 1)
        _ = fcntl(inP[1], F_SETFD, FD_CLOEXEC); _ = fcntl(outP[0], F_SETFD, FD_CLOEXEC)
        log.line("hittest \(bottle): started")
        return (p, inP[1], outP[0])
    }
}
