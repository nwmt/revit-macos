// ProcessEngine against the fake engine: short queries, long runs in a session of their own, Cancel's INT to the
// group, a run that outlives the process that started it, and the environment and descriptors a run gets.
import Darwin
import Foundation
import Testing
@testable import AppCore

@Suite(.serialized) struct ProcessEngineTests {
    let root = tempDir()

    func engine(_ fake: [String: String] = [:]) -> ProcessEngine {
        ProcessEngine(engine: fakeEngine, environment: TestEnv.make(root: root, fake: fake))
    }

    func newCtx(_ name: String = "run-1") -> URL {
        let c = root.appending(path: "data/logs/runs").appending(path: name)
        try! FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        return c
    }

    func lastEvent(_ ctx: URL) -> EngineEvent? {
        text(ctx.appending(path: "events.ndjson")).split(separator: "\n").last.flatMap { EventParser.parse(String($0)) }
    }

    func isStopped(_ ctx: URL) -> Bool {
        if case .end(let e)? = lastEvent(ctx) { return e.kind == .stopped }
        return false
    }

    @Test func runCapturesStdoutStderrAndANonZeroExit() async throws {
        let dir = root.appending(path: "fake"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = Data(#"{"bottles":[]}"#.utf8) + Data("\n".utf8)
        try json.write(to: dir.appending(path: "status.json"))
        let e = engine(["FAKE_DIR": dir.path])
        let ok = try await e.run(["status", "--json"])
        #expect(ok.stdout == json); #expect(ok.exitCode == 0)
        let bad = try await e.run(["fail"])
        #expect(bad.exitCode == 3); #expect(bad.stderr == "boom\n")
    }

    @Test func runReadsLargeOutputWithoutDeadlock() async throws {
        let dir = root.appending(path: "fake"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let big = String(repeating: "x", count: 300_000)
        try Data(big.utf8).write(to: dir.appending(path: "big.json")); try Data(big.utf8).write(to: dir.appending(path: "bigerr.err"))
        let out = try await engine(["FAKE_DIR": dir.path]).run(["big"])
        #expect(out.stdout.count == 300_000)
        let err = try await engine(["FAKE_DIR": dir.path]).run(["bigerr"])
        #expect(err.stderr.count == 300_000); #expect(err.exitCode == 1)
    }

    @Test func startTheRunIsItsOwnSessionLeader() async throws {
        let ctx = newCtx()
        let e = engine(["FAKE_SCENARIO": "slow"])
        let pid = try await e.start(["install", "2025", "rvt2025-a", "--yes"], ctx: ctx)
        defer { killGroup(pid) }
        #expect(await waitFor { !text(ctx.appending(path: "pgid.txt")).isEmpty })
        #expect(Int32(text(ctx.appending(path: "pgid.txt")).trimmingCharacters(in: .whitespacesAndNewlines)) == pid)
        #expect(await e.isSessionLeader(pid)); #expect(pid != getpgrp())
        #expect(await waitFor { text(ctx.appending(path: "stdin.txt")) == "eof\n" })
        #expect(await waitFor { text(ctx.appending(path: "console.log")).contains("hello err") })
        #expect(text(ctx.appending(path: "console.log")).contains("hello out"))
        #expect(text(ctx.appending(path: "args.txt")) == ["install", "2025", "rvt2025-a", "--yes", "--events", ctx.path].joined(separator: "\n") + "\n")
    }

    @Test func interruptStopsTheRunAndEverythingInItsGroup() async throws {
        let ctx = newCtx()
        let e = engine(["FAKE_SCENARIO": "slow"])
        let pid = try await e.start(["install", "2025", "rvt2025-a", "--yes"], ctx: ctx)
        defer { killGroup(pid) }
        #expect(await waitFor { text(ctx.appending(path: "events.ndjson")).contains("unpack") })
        let st = try #require(await e.processStart(pid: pid))
        #expect(await e.interrupt(pid: pid, pidStart: st))
        #expect(await waitFor { isStopped(ctx) })
        #expect(await waitFor { pgrepGroup(pid).isEmpty })
    }

    @Test func anINTTheAppIgnoresStillReachesTheEngine() async throws {
        let old = signal(SIGINT, SIG_IGN)
        defer { signal(SIGINT, old) }
        let ctx = newCtx()
        let e = engine(["FAKE_SCENARIO": "slow"])
        let pid = try await e.start(["install", "2025", "rvt2025-a", "--yes"], ctx: ctx)
        defer { killGroup(pid) }
        #expect(await waitFor { text(ctx.appending(path: "events.ndjson")).contains("unpack") })
        let st = try #require(await e.processStart(pid: pid))
        #expect(await e.interrupt(pid: pid, pidStart: st))
        #expect(await waitFor { isStopped(ctx) })
    }

    @Test func theRunSurvivesItsLauncher() async throws {
        let probe = try #require(ProcessInfo.processInfo.environment["SPAWN_PROBE"], "run app/test.sh: it builds SpawnProbe")
        let ctx = newCtx()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: probe)
        p.arguments = [fakeEngine.path, ctx.path, "install", "2025", "rvt2025-a", "--yes"]
        p.environment = TestEnv.make(root: root, fake: ["FAKE_SCENARIO": "slow"])
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let line = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let pid = try #require(Int32(parts.first ?? ""))
        defer { killGroup(pid) }
        let start = parts.count > 1 ? parts[1] : ""
        let fresh = engine()
        #expect(await fresh.processStart(pid: pid) == start)
        #expect(await fresh.isSessionLeader(pid))
        #expect(await waitFor { text(ctx.appending(path: "events.ndjson")).contains("unpack") })
        #expect(await fresh.interrupt(pid: pid, pidStart: start))
        #expect(await waitFor { isStopped(ctx) })
    }

    @Test func theEnvironmentIsMinimalAndUTF8() async throws {
        let env = EngineEnvironment.make(from: ["HOME": "/h", "USER": "x", "LOGNAME": "x", "TMPDIR": "/t", "PATH": "/opt/x",
            "REVIT_RUN_CTX": "/x", "REVIT_EVENTS_FD": "7", "REVIT_ACCEPT_EULA": "enscape", "REVIT_DATA": "/d",
            "FAKE_SCENARIO": "ok", "LEAK_TEST": "1"])
        #expect(env == ["HOME": "/h", "USER": "x", "LOGNAME": "x", "TMPDIR": "/t", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                        "LANG": "en_US.UTF-8", "REVIT_DATA": "/d", "FAKE_SCENARIO": "ok"])
        #expect(EngineEnvironment.make(from: ["HOME": "/h"]) == ["HOME": "/h", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"])
        let given = TestEnv.make(root: root, fake: ["FAKE_SCENARIO": "ok"])
        let ctx = newCtx()
        let pid = try await ProcessEngine(engine: fakeEngine, environment: given).start(["install"], ctx: ctx)
        defer { killGroup(pid) }
        #expect(await waitFor { !text(ctx.appending(path: "env.txt")).isEmpty && text(ctx.appending(path: "fds.txt")) != "" })
        var seen: [String: String] = [:]
        for l in text(ctx.appending(path: "env.txt")).split(separator: "\n") {
            let kv = l.split(separator: "=", maxSplits: 1).map(String.init); if kv.count == 2 { seen[kv[0]] = kv[1] }
        }
        for k in ["PWD", "SHLVL", "_"] { seen[k] = nil }      // bash sets these itself
        #expect(seen == given)
    }

    @Test func noDescriptorOfTheAppLeaks() async throws {
        let f = root.appending(path: "open.txt"); FileManager.default.createFile(atPath: f.path, contents: nil)
        let fd = open(f.path, O_RDONLY); defer { close(fd) }
        #expect(fd > 2)
        let ctx = newCtx()
        let pid = try await engine().start(["install"], ctx: ctx)
        defer { killGroup(pid) }
        #expect(await waitFor { !text(ctx.appending(path: "fds.txt")).isEmpty })
        let fds = text(ctx.appending(path: "fds.txt")).split(separator: "\n").map(String.init)
        #expect(!fds.contains(String(fd)))
    }

    @Test func argumentsWithSpacesAndNonASCIIArriveIntact() async throws {
        let ctx = newCtx("run dir \u{E4}")
        let pid = try await engine().start(["link-installer", "2025", "/tmp/Revit Installer \u{FC}"], ctx: ctx)
        defer { killGroup(pid) }
        #expect(await waitFor { text(ctx.appending(path: "args.txt")).contains("--events") })
        #expect(text(ctx.appending(path: "args.txt")) == ["link-installer", "2025", "/tmp/Revit Installer \u{FC}", "--events", ctx.path].joined(separator: "\n") + "\n")
    }

    @Test func processStartMatchesPsAndIsNilForDeadAndZero() async throws {
        let e = engine()
        let me = getpid()
        let expected = psStart(me)
        #expect(await e.processStart(pid: me) == expected)
        #expect(await e.processStart(pid: 0) == nil)
        let gone = Process(); gone.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try gone.run(); gone.waitUntilExit()
        #expect(await e.processStart(pid: gone.processIdentifier) == nil)
    }

    @Test func interruptRefusesWhatIsNotTheRun() async throws {
        let e = engine()
        let sleeper = Process(); sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["30"]
        try sleeper.run(); defer { sleeper.terminate() }
        let pid = sleeper.processIdentifier
        let st = try #require(await e.processStart(pid: pid))
        #expect(await e.interrupt(pid: 0, pidStart: st) == false)
        #expect(await e.interrupt(pid: 1, pidStart: st) == false)
        #expect(await e.interrupt(pid: -pid, pidStart: st) == false)
        #expect(await e.interrupt(pid: pid, pidStart: "") == false)
        #expect(await e.interrupt(pid: pid, pidStart: "Mon Jan  1 00:00:00 2001") == false)
        #expect(await e.interrupt(pid: pid, pidStart: st) == false)    // its own pid, not its session
        #expect(kill(pid, 0) == 0)                                      // still alive
    }

    @Test func isSessionLeaderIsFalseForTheTestProcess() async { #expect(await engine().isSessionLeader(getpid()) == false) }

    @Test func engineLocatorFindsTheEngine() throws {
        let res = root.appending(path: "Resources"); let eng = res.appending(path: "engine/revit")
        try FileManager.default.createDirectory(at: eng.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: eng.path, contents: Data())
        #expect(EngineLocator.find(resources: res, env: ["APP_ENGINE": "/dev/x/revit"])?.path == "/dev/x/revit")
        #expect(EngineLocator.find(resources: res, env: [:])?.path == eng.path)
        #expect(EngineLocator.find(resources: root.appending(path: "none"), env: [:]) == nil)
        #expect(EngineLocator.find(resources: nil, env: [:]) == nil)
    }
}

/// `ps -o lstart=` of a pid, trimmed.
func psStart(_ pid: Int32) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-o", "lstart=", "-p", String(pid)]
    let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The pids in a process group (pgrep -g).
func pgrepGroup(_ pgid: Int32) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-g", String(pgid)]
    let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
