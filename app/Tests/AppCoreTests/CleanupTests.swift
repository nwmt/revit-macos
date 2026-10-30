// Programs left running (./revit cleanup): the model's arguments and answers against the Swift fake, the sweep after a
// Revit quits, and the real engine closing a fake leftover in a sandbox.
import Foundation
import Testing
@testable import AppCore

/// A status --json answer with one bottle, Revit running there or not.
func statusWith(running: Bool) -> EngineOutput {
    let json = """
    {"crossover":{"found":true,"path":"/x","version":"26.3.0","supported":true},"rosetta":true,"msls31":true,\
    "busy":{"busy":false,"command":"","run_id":"","pid":"","pid_start":"","pgid":"","ctx":""},\
    "bottles":[{"name":"rvt2027-a","year":"2027","revit":true,"running":\(running),"addins":[]}]}
    """
    return EngineOutput(stdout: Data(json.utf8), stderr: "", exitCode: 0)
}

let leftoverJSON = #"{"items":[{"pid":24030,"kind":"wine","reason":"bottle_gone","bottle":"probe-drag","name":"winedevice.exe","cpu":99.6,"age_s":30600,"start":1761641129000000,"revit":false},{"pid":38935,"kind":"helper","reason":"parent_gone","bottle":null,"name":"T Trackpad","cpu":1.0,"age_s":150000,"start":1761500000123456,"revit":false}],"skipped":[{"bottle":"rvt2027-a","why":"revit_running"}]"#

@MainActor @Suite(.serialized) struct CleanupTests {

    @Test func reportDecodesAndReadsAsLines() throws {
        let r = try JSONDecoder.engine.decode(CleanupReport.self, from: Data((leftoverJSON + "}").utf8))
        #expect(r.items.count == 2 && r.closed == nil && r.left == nil)
        #expect(r.planLines == ["winedevice.exe · probe-drag (deleted) · 100% CPU · 8 h 30 min", "T Trackpad · 1% CPU · 1 d 17 h"])
        #expect(Leftover.age(59) == "0 min")
        let revit = Leftover(pid: 1, kind: "wine", reason: "all", bottle: "rvt2027-a", name: "Revit.exe", cpu: 3, ageS: 60,
                             start: 1, revit: true)
        #expect(CleanupReport(items: [revit], skipped: []).planLines.last == "Revit closes without saving: unsaved changes are lost.")
    }

    @Test func closeAllPassesTheExactArgsAndReportsWhatIsLeft() async {
        let h = Harness()
        await h.fake.set(query: ["cleanup", "--all", "--dry-run", "--json"], EngineOutput(stdout: Data((leftoverJSON + "}").utf8), stderr: "", exitCode: 0))
        await h.fake.set(query: ["cleanup", "--all", "--targets", "24030:1761641129000000,38935:1761500000123456", "--json"],
                         EngineOutput(stdout: Data((leftoverJSON + #","closed":[38935],"left":[24030]}"#).utf8), stderr: "", exitCode: 1))
        guard case let .report(p) = await h.model.cleanup(all: true, dryRun: true) else { Issue.record("no plan"); return }
        #expect(p.items.map(\.pid) == [24030, 38935])
        guard case let .report(r) = await h.model.cleanup(all: true, dryRun: false, targets: p.items) else { Issue.record("no report"); return }
        #expect(r.closed == [38935] && r.left == [24030])   // exit 1 with a report is still a report
    }

    @Test func aRefusalIsTheEnginesWords() async {
        let h = Harness()
        await h.fake.set(query: ["cleanup", "--json"], EngineOutput(stdout: Data(), stderr: "Another task is running: install.sh 2027 rvt2027-a.\n", exitCode: 1))
        #expect(await h.model.cleanup(all: false, dryRun: false) == .refused("Another task is running: install.sh 2027 rvt2027-a."))
    }

    @Test func aRevitThatQuitsStartsOneSweepThatNotifies() async {
        let h = Harness()
        await h.fake.setStatus([statusWith(running: true), statusWith(running: false)])
        await h.fake.set(query: ["cleanup", "--json"], EngineOutput(stdout: Data((leftoverJSON + #","closed":[24030,38935],"left":[]}"#).utf8), stderr: "", exitCode: 0))
        await h.model.refresh()
        #expect(h.model.sweepTask == nil)              // Revit started: nothing to sweep
        await h.model.refresh()
        await h.model.sweepTask?.value
        #expect(await h.fake.calls.filter { $0 == "run cleanup --json" }.count == 1)
        #expect(h.notifier.posts.map(\.body) == ["winedevice.exe, T Trackpad"])
        await h.model.refresh()                        // still not running: no second sweep
        await h.model.sweepTask?.value
        #expect(await h.fake.calls.filter { $0 == "run cleanup --json" }.count == 1)
    }

    @Test func noSweepWhileATaskRunsAndNoNotificationOnQuit() async throws {
        let h = Harness()
        await h.fake.set(query: ["cleanup", "--json"], EngineOutput(stdout: Data((leftoverJSON + #","closed":[24030],"left":[]}"#).utf8), stderr: "", exitCode: 0))
        try await h.model.start(install)
        #expect(await h.model.sweep(notify: false) == nil)
        await h.fake.emit([endOK]); await h.model.poll()
        let posts = h.notifier.posts.count            // the run's own notification
        #expect(await h.model.sweep(notify: false)?.closed == [24030])
        #expect(h.notifier.posts.count == posts)
    }

    /// A Wine process as the engine tells one: its executable inside the CrossOver folder (a copy of perl there),
    /// argv[0] as Wine sets it, WINEPREFIX its bottle. It ignores TERM, as winedevice.exe does.
    func wine(_ cx: URL, _ name: String, prefix: String) throws -> Process {
        let exe = cx.appending(path: "lib/wine/x86_64-unix/wine")
        if !FileManager.default.fileExists(atPath: exe.path) {
            try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: "/usr/bin/perl", toPath: exe.path)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", #"exec -a "$2" "$1" -e '$SIG{TERM} = "IGNORE"; sleep 60'"#, "x", exe.path, name]
        p.environment = ["WINEPREFIX": prefix, "PATH": "/usr/bin:/bin"]
        try p.run()
        return p
    }

    @Test func theRealEngineClosesAllOfWineButOnlyWhatWasShown() async throws {
        let root = tempDir()
        var env = TestEnv.make(root: root)
        env["REVIT_CLEANUP_ONLY"] = root.path; env["REVIT_CLEANUP_AGE"] = "0"   // only this test's fakes count
        let cx = URL(fileURLWithPath: env["REVIT_CX"]!), bottle = root.appending(path: "home/Library/Application Support/CrossOver/Bottles/rvt2027-a")
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        let revit = try wine(cx, #"C:\Program Files\Autodesk\Revit 2027\Revit.exe"#, prefix: bottle.path)
        defer { if revit.isRunning { kill(revit.processIdentifier, SIGKILL) } }
        try await Task.sleep(for: .milliseconds(500))
        let m = AppModel(engine: ProcessEngine(engine: repoEngine, environment: env), defaults: TestDefaults.make(), notifier: FakeNotifier())
        guard case let .report(p) = await m.cleanup(all: true, dryRun: true) else { Issue.record("no plan"); return }
        #expect(p.items.map(\.pid) == [revit.processIdentifier] && p.items.first?.revit == true && p.items.first?.bottle == "rvt2027-a")
        let later = try wine(cx, #"C:\windows\system32\conhost.exe"#, prefix: bottle.path)   // after the list was shown
        defer { if later.isRunning { kill(later.processIdentifier, SIGKILL) } }
        try await Task.sleep(for: .milliseconds(300))
        guard case let .report(r) = await m.cleanup(all: true, dryRun: false, targets: p.items) else { Issue.record("no report"); return }
        #expect(r.closed == [revit.processIdentifier] && r.left == [])
        #expect(later.isRunning)
        revit.waitUntilExit()
        #expect(revit.terminationReason == .uncaughtSignal)
    }
}
