// The real EngineClient: /bin/bash <engine> <args…> with an argument list (never a shell string) and the
// environment given (EngineEnvironment.make). Long runs start with posix_spawn in a new session, so Cancel's INT to
// the group reaches only the engine, and the run goes on when the app quits.
import Darwin
import Foundation

/// One pipe's bytes: written by its reader before the group's leave, read after the wait.
private final class Collected: @unchecked Sendable { var data = Data() }

public struct EngineStartError: Error, CustomStringConvertible {
    public let description: String
}

public final class ProcessEngine: EngineClient, Sendable {
    let engine: URL
    let environment: [String: String]

    public init(engine: URL, environment: [String: String]) {
        self.engine = engine
        self.environment = environment
    }

    public func run(_ args: [String]) async throws -> EngineOutput {
        let engine = engine, environment = environment
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [engine.path] + args
                p.environment = environment
                p.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err
                do { try p.run() } catch { cont.resume(throwing: error); return }
                // both pipes at once: a full stderr pipe must not block a reader waiting on stdout
                let o = Collected(), e = Collected()
                let g = DispatchGroup()
                g.enter(); DispatchQueue.global().async { o.data = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                g.enter(); DispatchQueue.global().async { e.data = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                g.wait(); p.waitUntilExit()
                cont.resume(returning: EngineOutput(stdout: o.data, stderr: String(decoding: e.data, as: UTF8.self), exitCode: p.terminationStatus))
            }
        }
    }

    public func start(_ args: [String], ctx: URL) async throws -> Int32 {
        var attr: posix_spawnattr_t? = nil
        var fa: posix_spawn_file_actions_t? = nil
        try check(posix_spawnattr_init(&attr), "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attr) }
        try check(posix_spawn_file_actions_init(&fa), "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&fa) }
        // its own session and group; no descriptor of the app; INT/TERM/HUP back to default and nothing blocked, whatever
        // the app ignores or blocks
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        try check(posix_spawnattr_setflags(&attr, Int16(flags)), "posix_spawnattr_setflags")
        var def = sigset_t(); sigemptyset(&def)
        for s in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE] { sigaddset(&def, s) }
        try check(posix_spawnattr_setsigdefault(&attr, &def), "posix_spawnattr_setsigdefault")
        var mask = sigset_t(); sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attr, &mask), "posix_spawnattr_setsigmask")
        let console = ctx.appending(path: "console.log").path
        try check(posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0), "addopen stdin")
        try check(posix_spawn_file_actions_addopen(&fa, 1, console, O_WRONLY | O_CREAT | O_APPEND, 0o644), "addopen console.log")
        try check(posix_spawn_file_actions_adddup2(&fa, 1, 2), "adddup2 stderr")

        let argv = ["/bin/bash", engine.path] + args + ["--events", ctx.path]
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnvp: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]
        defer { for p in cArgv { free(p) }; for p in cEnvp { free(p) } }
        var pid: pid_t = 0
        try check(posix_spawn(&pid, "/bin/bash", &fa, &attr, &cArgv, &cEnvp), "posix_spawn")
        // reap it whenever it ends, so it never stays a zombie; its end event carries the result
        let child = pid
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1 && errno == EINTR {}
        }
        return pid
    }

    public func interrupt(pid: Int32, pidStart: String) async -> Bool {
        guard pid > 1, !pidStart.isEmpty, Self.lstart(pid) == pidStart, getsid(pid) == pid, getpgid(pid) == pid else { return false }
        return kill(-pid, SIGINT) == 0
    }

    public func processStart(pid: Int32) async -> String? { Self.lstart(pid) }

    public func isSessionLeader(_ pid: Int32) async -> Bool { pid > 1 && getsid(pid) == pid && getpgid(pid) == pid }

    /// `/bin/ps -o lstart= -p <pid>`, trimmed; nil when gone or pid ≤ 0.
    static func lstart(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "lstart=", "-p", String(pid)]
        p.environment = ["LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin"]   // as the engine runs ps for lock.owner
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !s.isEmpty ? s : nil
    }

    private func check(_ rc: Int32, _ what: String) throws {
        guard rc == 0 else { throw EngineStartError(description: "\(what): \(String(cString: strerror(rc)))") }
    }
}
