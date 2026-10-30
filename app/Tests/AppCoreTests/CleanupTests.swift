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

let leftoverJSON = #"{"items":[{"pid":24030,"kind":"wine","reason":"bottle_gone","bottle":"probe-drag","name":"winedevice.exe","cpu":99.6,"age_s":30600,"start":1761641129},{"pid":38935,"kind":"helper","reason":"parent_gone","bottle":null,"name":"T Trackpad","cpu":1.0,"age_s":150000,"start":1761500000}],"skipped":[{"bottle":"rvt2027-a","why":"revit_running"}]"#

@MainActor @Suite(.serialized) struct CleanupTests {

    @Test func reportDecodesAndReadsAsLines() throws {
        let r = try JSONDecoder.engine.decode(CleanupReport.self, from: Data((leftoverJSON + "}").utf8))
        #expect(r.items.count == 2 && r.closed == nil && r.left == nil)
        #expect(r.planLines == ["winedevice.exe · probe-drag (deleted) · 100% CPU · 8 h 30 min",
                                "T Trackpad · 1% CPU · 1 d 17 h", "Left alone: rvt2027-a (Revit runs there)"])
        #expect(Leftover.age(59) == "0 min")
    }

    @Test func closeAllPassesTheExactArgsAndReportsWhatIsLeft() async {
        let h = Harness()
        await h.fake.set(query: ["cleanup", "--all", "--dry-run", "--json"], EngineOutput(stdout: Data((leftoverJSON + "}").utf8), stderr: "", exitCode: 0))
        await h.fake.set(query: ["cleanup", "--all", "--targets", "24030:1761641129,38935:1761500000", "--json"],
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

    @Test func theRealEngineClosesALeftoverOfADeletedBottle() async throws {
        let root = tempDir()
        var env = TestEnv.make(root: root)
        env["REVIT_CLEANUP_ONLY"] = root.path; env["REVIT_CLEANUP_AGE"] = "0"   // only this test's fake counts
        let held = root.appending(path: "home/Library/Application Support/CrossOver/Bottles/gone/drive_c/windows")
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
        let fake = Process()   // a Windows program that ignores TERM, as winedevice.exe does, in a bottle then deleted
        fake.executableURL = URL(fileURLWithPath: "/bin/bash")
        fake.arguments = ["-c", #"cd "$1" && exec -a 'C:\windows\system32\winedevice.exe' perl -e '$SIG{TERM} = "IGNORE"; sleep 60' "$1""#, "x", held.path]
        try fake.run()
        defer { if fake.isRunning { kill(fake.processIdentifier, SIGKILL) } }
        try await Task.sleep(for: .milliseconds(500))
        try FileManager.default.removeItem(at: held.deletingLastPathComponent().deletingLastPathComponent())
        let m = AppModel(engine: ProcessEngine(engine: repoEngine, environment: env), defaults: TestDefaults.make(), notifier: FakeNotifier())
        guard case let .report(p) = await m.cleanup(all: true, dryRun: true) else { Issue.record("no plan"); return }
        #expect(p.items.map(\.pid) == [fake.processIdentifier] && p.items.first?.reason == "bottle_gone")
        let later = Process()   // found after the list was shown: Close all does not end it without asking
        later.executableURL = URL(fileURLWithPath: "/bin/bash")
        later.arguments = ["-c", #"exec -a 'C:\windows\system32\conhost.exe' perl -e 'sleep 60' "$1""#, "x", root.path]
        try later.run()
        defer { if later.isRunning { kill(later.processIdentifier, SIGKILL) } }
        try await Task.sleep(for: .milliseconds(300))
        guard case let .report(r) = await m.cleanup(all: true, dryRun: false, targets: p.items) else { Issue.record("no report"); return }
        #expect(r.closed == [fake.processIdentifier] && r.left == [])
        #expect(later.isRunning)
        fake.waitUntilExit()
        #expect(fake.terminationReason == .uncaughtSignal)
    }
}
