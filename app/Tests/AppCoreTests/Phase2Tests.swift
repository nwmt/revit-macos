// The everyday and recovery screens: recent files, Update Revit, the ladder, Start with a log, Prepare a folder.
import Foundation
import Testing
@testable import AppCore

@MainActor @Suite struct Phase2Tests {
    private func answer(_ s: String, code: Int32 = 0, err: String = "") -> EngineOutput {
        EngineOutput(stdout: Data(s.utf8), stderr: err, exitCode: code)
    }

    @Test func updateArgumentsAndPlanReadCarryTheFolder() {
        let r = RunRequest.update(year: 2027, bottle: "b", from: "/f")
        #expect(r.arguments == ["update", "2027", "b", "--yes", "--from", "/f"])
        #expect(r.planArguments == ["update", "2027", "b", "--from", "/f", "--dry-run", "--json"])
        #expect(r.keeping(point: false).arguments.last == "--no-point")
        #expect(r.needsSheet && r.cancellable && r.year == 2027 && r.bottle == "b")
        #expect(RunRequest.rebuild(year: 2027, bottle: "b", source: nil).planArguments == ["rebuild", "2027", "b", "--dry-run", "--json"])
    }

    @Test func aFolderWithAnAddressIsNotWrittenDown() {
        let r = RunRequest.update(year: 2027, bottle: "b", from: "/Volumes/x/CloudStorage/GoogleDrive-a@b.c/My Drive")
        #expect(r.persistable == .update(year: 2027, bottle: "b", from: ""))
        #expect(r.persistable.lostAddress && !r.lostAddress)
        let plain = RunRequest.update(year: 2027, bottle: "b", from: "/Volumes/x/Revit")
        #expect(plain.persistable == plain)
    }

    @Test func oldRunRecordsStillDecode() throws {
        let d = Data(#"{"rebuild":{"year":2027,"bottle":"b"}}"#.utf8)
        #expect(try JSONDecoder().decode(RunRequest.self, from: d) == .rebuild(year: 2027, bottle: "b", source: nil))
    }

    @Test func updatePlanFingerprintSeesTheFolderAndTheBlock() throws {
        func plan(_ from: String, _ blocked: String = "") throws -> RemovePlan {
            try JSONDecoder.engine.decode(RemovePlan.self, from: Data("""
            {"command":"update","year":2027,"bottle":"b","delete":[],"notes":[],"from":"\(from)","build_now":"27.3","build_new":"27.4","newer":true,"blocked":"\(blocked)"}
            """.utf8))
        }
        let p = try plan("/a")
        #expect(p.buildNow == "27.3" && p.newer == true)
        #expect(p.fingerprint == (try plan("/a")).fingerprint)
        #expect(p.fingerprint != (try plan("/b")).fingerprint)
        #expect(p.fingerprint != (try plan("/a", "no")).fingerprint)
    }

    @Test func ladderSaysWhyAStepIsOff() {
        func off(running: Bool, busy: Bool, newest: String?) -> [String?] {
            RecoverContent.steps(year: 2027, running: running, busy: busy, newest: newest).map(\.off)
        }
        #expect(RecoverContent.steps(year: 2027, running: true, busy: false, newest: "p").count == 7)
        let run = off(running: true, busy: false, newest: "p")
        #expect(run[0] == nil && run[1] == nil && run[2] == nil && run[3] == nil && run[5] == nil)
        #expect(run[4] != nil && run[6] != nil)       // rollback and rebuild want Revit closed
        let idle = off(running: false, busy: false, newest: "p")
        #expect(idle[0] != nil && idle[1] != nil && idle[4] == nil && idle[6] == nil)
        #expect(off(running: false, busy: false, newest: nil)[4] != nil)
        let busy = off(running: false, busy: true, newest: "p")
        #expect(busy[2] != nil && busy[4] != nil && busy[6] != nil && busy[3] == nil && busy[5] == nil)
        let last = RecoverContent.steps(year: 2027, running: false, busy: false, newest: "p")
        #expect(last[4].action == .rollBack("p") && last[6].danger)
    }

    @Test func recentPrefersWhatIsPickedThenWhatRuns() {
        func card(_ n: String, running: Bool = false) -> VersionCard {
            VersionCard(year: 2027, bottle: n, status: "works", tested: "", note: "", running: running, starting: false, hasPoint: false, taskHere: false, pids: [])
        }
        let c = [card("a"), card("b", running: true)]
        #expect(RecentChoice.bottle(c, picked: nil)?.bottle == "b")
        #expect(RecentChoice.bottle(c, picked: "a")?.bottle == "a")
        #expect(RecentChoice.bottle(c, picked: "gone")?.bottle == "b")
        #expect(RecentChoice.bottle([], picked: nil) == nil)
    }

    @Test func menuShowsFiveRecentThatCanOpen() {
        let files = (1...7).map { RecentFile(name: "\($0).rvt", kind: "rvt", where: "", path: $0 == 1 ? nil : "/\($0)") }
        let s = try? windowStatus(#"{"name":"rvt2027-a","year":"2027","revit":true,"running":false,"addins":[]}"#)
        let m = MenuContent.make(status: s, watched: nil, failure: nil, busy: false, recent: ["rvt2027-a": files])
        #expect(m.bottles[0].recent.map(\.name) == ["2.rvt", "3.rvt", "4.rvt", "5.rvt", "6.rvt"])
    }

    @Test func recentIsReadAndABadAnswerKeepsTheList() async {
        let e = FakeEngine()
        let m = AppModel(engine: e, defaults: TestDefaults.make(), notifier: FakeNotifier(), dataOverride: nil)
        let b = bottle()
        await e.set(query: ["recent", "2027", "rvt2027-a", "--json"], answer(#"{"command":"recent","year":2027,"bottle":"rvt2027-a","files":[{"name":"a.rvt","kind":"rvt","where":"G:","path":null}]}"#))
        await m.refreshRecent(b)
        #expect(m.recent["rvt2027-a"]?.first?.path == nil && m.recent["rvt2027-a"]?.count == 1)
        await e.set(query: ["recent", "2027", "rvt2027-a", "--json"], answer("nope"))
        await m.refreshRecent(b)
        #expect(m.recent["rvt2027-a"]?.count == 1)
    }

    @Test func debugShowsStartingAndGivesBackARefusal() async {
        let e = FakeEngine()
        let m = AppModel(engine: e, defaults: TestDefaults.make(), notifier: FakeNotifier(), dataOverride: nil)
        await e.set(query: ["debug", "2027", "b"], answer("", code: 75, err: "Another task is running. Try again later.\n"))
        #expect(await m.debug(year: 2027, bottle: "b") == .refused("Another task is running. Try again later."))
        #expect(m.revitStarting["b"] == nil)
        await e.set(query: ["debug", "2027", "b"], answer("ok"))
        #expect(await m.debug(year: 2027, bottle: "b") == .started)
        #expect(m.revitStarting["b"] != nil)
    }

    @Test func emptyTargetsCloseNothing() async {
        let e = FakeEngine()
        let m = AppModel(engine: e, defaults: TestDefaults.make(), notifier: FakeNotifier(), dataOverride: nil)
        _ = await m.cleanup(all: false, dryRun: false, targets: [])
        #expect(await e.calls.isEmpty)
    }

    @Test func launchClosesOnlyAnOrphanedListing() async {
        let e = FakeEngine()
        let m = AppModel(engine: e, defaults: TestDefaults.make(), notifier: FakeNotifier(), dataOverride: nil)
        let item = { (kind: String, reason: String, pid: Int) in
            #"{"pid":\#(pid),"kind":"\#(kind)","reason":"\#(reason)","bottle":"b","name":"n","cpu":0,"age_s":1,"start":5,"revit":false}"#
        }
        await e.set(query: ["cleanup", "--dry-run", "--json"], answer(#"{"items":[\#(item("wine", "no_wineserver", 1))],"skipped":[]}"#))
        await m.closeOrphanWarm()
        #expect(await e.calls.count == 1)
        await e.set(query: ["cleanup", "--dry-run", "--json"], answer(#"{"items":[\#(item("wine", "no_wineserver", 1)),\#(item("gdrive", "parent_gone", 2))],"skipped":[]}"#))
        await m.closeOrphanWarm()
        let last = await e.calls.last ?? ""
        #expect(last.contains("--targets 2:5") && !last.contains("1:5"))
    }

    @Test func warmEndsWithItsLastCountOrItsRefusal() async {
        let e = FakeEngine()
        let w = WarmModel(engine: e)
        let args = ["gdrive", "warm", "2027", "b", "G:\\x", "--depth", "2"]
        await e.set(query: args, answer("3 folders listed, 1 were cloud-only\ndeeper folders were not listed\n"))
        w.start(year: 2027, bottle: "b", folder: "G:\\x", depth: 2)
        #expect(w.running)
        for _ in 0..<500 where w.running { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(w.line == "3 folders listed, 1 were cloud-only" && !w.failed)
        await e.set(query: args, answer("3 folders listed\n2 folders could not be listed\n", code: 1))
        w.start(year: 2027, bottle: "b", folder: "G:\\x", depth: 2)
        for _ in 0..<500 where w.running { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(w.line == "2 folders could not be listed" && w.failed)
        await e.set(query: args, answer("", code: 1, err: "not a folder of G:\n"))
        w.start(year: 2027, bottle: "b", folder: "G:\\x", depth: 2)
        for _ in 0..<500 where w.running { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(w.line == "not a folder of G:" && w.failed)
    }

    @Test func streamGivesLinesAsTheyComeAndCancelEndsIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appending(path: "revit")
        try "echo one\nsleep 30\necho two\n".write(to: script, atomically: true, encoding: .utf8)
        let e = ProcessEngine(engine: script, environment: ["PATH": "/usr/bin:/bin"])
        actor Lines { var all: [String] = []; func add(_ s: String) { all.append(s) } }
        let lines = Lines()
        let t = Task { try await e.stream(["x"]) { l in Task { await lines.add(l) } } }
        for _ in 0..<500 where await lines.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await lines.all == ["one"])
        let began = Date()
        t.cancel()
        let out = try await t.value
        #expect(out.exitCode != 0 && Date().timeIntervalSince(began) < 3)
    }
}
