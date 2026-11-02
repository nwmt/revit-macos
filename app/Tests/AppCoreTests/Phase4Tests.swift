// Phase 4: the install's plan and phases, the sign-in hint, Storage's restore points, This Mac, one sheet at a time.
import Foundation
import Testing
@testable import AppCore

@MainActor @Suite(.serialized) struct Phase4Tests {

    // MARK: plan and phases

    @Test func planEvent() {
        #expect(EventParser.parse(#"{"event":"plan","actions":["shims","bottle"],"steps":["vc","rvt"]}"#)
                == .plan(InstallPlan(actions: ["shims", "bottle"], steps: ["vc", "rvt"])))
        #expect(EventParser.parse(#"{"event":"plan","actions":"shims","steps":[]}"#) == nil)
        #expect(EventParser.parse(#"{"event":"plan","actions":["shims"]}"#) == nil)
    }

    @Test func anOldRunHasNoPlan() {
        let s = RunState.replay(eventLines("install-ok.ndjson").compactMap(EventParser.parse))
        #expect(s.plan == nil)
        let ids = InstallPhases.make(s).map(\.id)
        #expect(ids.first == "shims"); #expect(Set(ids) == Set(s.actions.map(\.id)))
    }

    @Test func phasesFollowThePlan() {
        var s = RunState()
        s.apply(.plan(InstallPlan(actions: ["shims", "revit", "redist", "unpack", "bottle", "steps", "apps"], steps: ["vc", "fonts", "rvt"])))
        s.apply(.action(id: "shims", state: "running", exit: nil))
        s.apply(.action(id: "shims", state: "done", exit: 0))
        s.apply(.action(id: "revit", state: "running", exit: nil))
        s.apply(.progress(step: "download", done: 25, total: 100))
        var p = InstallPhases.make(s)
        #expect(p.map(\.title) == ["Prepare", "Download Revit", "Download runtimes", "Unpack", "Create the bottle", "Install Revit and fixes", "Make the apps"])
        #expect(p[0].state == .done); #expect(p[1].state == .running); #expect(p[2].state == .todo)
        #expect(p[1].percent == 25); #expect(p[1].detail.hasPrefix("Current file: 25%"))
        s.apply(.action(id: "revit", state: "done", exit: 0))
        s.apply(.action(id: "steps", state: "running", exit: nil))
        s.apply(.step(id: "vc", state: "done", detail: nil))
        s.apply(.step(id: "fonts", state: "running", detail: nil))
        p = InstallPhases.make(s)
        #expect(p[5].detail == "1 of 3 · fonts"); #expect(p[1].percent == nil)
    }

    @Test func anUnknownActionKeepsItsId() {
        var s = RunState()
        s.apply(.plan(InstallPlan(actions: ["shims", "warp"], steps: [])))
        s.apply(.action(id: "warp", state: "failed", exit: 1))
        let p = InstallPhases.make(s)
        #expect(p.map(\.title) == ["Prepare", "warp"]); #expect(p[1].state == .failed)
    }

    // MARK: sign-in

    @Test func theHintShowsOncePerInstall() {
        let d = TestDefaults.make(); defer { TestDefaults.remove(d) }
        let h = SignInHint(defaults: d)
        #expect(!h.due(bottle: "rvt2027-a", builtTime: nil))
        #expect(h.due(bottle: "rvt2027-a", builtTime: "t1"))
        h.mark(bottle: "rvt2027-a", builtTime: "t1")
        #expect(!h.due(bottle: "rvt2027-a", builtTime: "t1"))
        #expect(h.due(bottle: "rvt2027-a", builtTime: "t2"))      // a rebuild is a new install
        #expect(h.due(bottle: "rvt2020-a", builtTime: "t1"))
        h.turnOff()
        #expect(!h.due(bottle: "rvt2020-a", builtTime: "t1"))
    }

    @Test func signInWords() {
        let w = SignInText.make(bottle: "rvt2020-a", signin: "adsso", idmgrBottles: ["rvt2027-a"])
        #expect(!w.browser); #expect(w.note == nil)
        let one = SignInText.make(bottle: "rvt2027-a", signin: "idmgr", idmgrBottles: ["rvt2027-a"])
        #expect(one.browser); #expect(one.note == nil); #expect(one.steps.last?.contains("Autodesk Sign-In (rvt2027-a)") == true)
        let two = SignInText.make(bottle: "rvt2027-a", signin: "idmgr", idmgrBottles: ["rvt2027-a", "rvt2025-a"])
        #expect(two.note?.contains("adskidmgr") == true)
    }

    // MARK: status, Storage, This Mac

    func status(_ points: String, leftovers: String = "[]", bottles: String = "") -> EngineStatus {
        let json = """
        {"crossover":{"found":true,"path":"/x","version":"26.3","supported":true},"rosetta":true,"msls31":true,\
        "busy":{"busy":false,"command":"","run_id":"","pid":"","pid_start":"","pgid":"","ctx":""},\
        "restore_points":[\(points)],"restore_leftovers":\(leftovers),"bottles":[\(bottles)]}
        """
        return try! EngineStatus.decode(Data(json.utf8))
    }
    func point(_ b: String, _ y: String, _ id: String, _ bytes: Int) -> String {
        #"{"bottle":"\#(b)","year":"\#(y)","id":"\#(id)","time":"t","bytes":\#(bytes)}"#
    }
    func bottle(_ b: String, _ y: String) -> String {
        #"{"name":"\#(b)","year":"\#(y)","revit":true,"running":false,"addins":[],"support":{"status":"works","tested":"x","gaps":"","signin":"idmgr"}}"#
    }

    @Test func statusDecodesTheNewKeys() {
        let s = status("", leftovers: #"["rvt2025-a"]"#, bottles: bottle("rvt2027-a", "2027"))
        #expect(s.restoreLeftovers == ["rvt2025-a"]); #expect(s.bottles[0].support?.signin == "idmgr")
        let old = try! JSONDecoder.engine.decode(Support.self, from: Data(#"{"status":"works","tested":"x","gaps":""}"#.utf8))
        #expect(old.signin == "")
    }

    @Test func storageRowsByBottleAndYear() {
        let s = status([point("rvt2027-a", "2027", "1", 10), point("rvt2027-a", "2027", "2", 5), point("rvt2025-a", "2025", "1", 7),
                        point("rvt2025-a", "2024", "1", 3), point("rvt2026-a", "2026", "1", 1)].joined(separator: ","),
                       leftovers: #"["rvt2025-a","rvt2023-x"]"#, bottles: [bottle("rvt2027-a", "2027"), bottle("rvt2025-a", "2025"), bottle("rvt2026-a", "2026")].joined(separator: ","))
        let c = StorageContent.make(s)
        #expect(c.points.count == 4)
        let a = c.points[0]
        #expect(a.bottle == "rvt2027-a" && a.count == 2 && a.bytes == 15 && !a.removed && a.action == .keepNewest && a.clear == "old")
        #expect(c.points[1].action == nil && !c.points[1].removed && c.points[1].unfinished)     // rvt2025-a 2025: one point
        #expect(c.points[2].year == 2024 && c.points[2].removed && c.points[2].action == .deleteAll && c.points[2].clear == "all")
        #expect(c.points[3].action == nil)
        #expect(c.leftoversOnly == ["rvt2023-x"])
    }

    @Test func thisMacLeavesOutTheTerminalAndTheTools() throws {
        let json = #"""
        {"checks":[{"id":"host.arm64","group":"host","status":"ok","title":"an Apple Silicon Mac","detail":"","fix":"","doc":""},
        {"id":"host.terminal","group":"host","status":"ok","title":"this Terminal","detail":"","fix":"","doc":""},
        {"id":"host.tool.7zz","group":"host","status":"ok","title":"7zz found","detail":"","fix":"","doc":""},
        {"id":"host.space.bottles","group":"host","status":"warn","title":"10 GB free","detail":"","fix":"free some space","doc":""},
        {"id":"crossover.found","group":"crossover","status":"ok","title":"CrossOver","detail":"","fix":"","doc":""}],
        "summary":{"fail":0,"warn":1,"ok":4,"info":0,"checks":5}}
        """#
        let r = try JSONDecoder.engine.decode(DoctorReport.self, from: Data(json.utf8))
        #expect(r.forApp.checks.map(\.id) == ["host.arm64", "host.tool.7zz", "host.space.bottles", "crossover.found"])
        #expect(r.mac.map(\.id) == ["host.arm64", "host.space.bottles"])
        #expect(r.mac[1].fix == "free some space")
    }

    @Test func launchOffersAddRevit() {
        #expect(LaunchRoute.pick(activeRun: false, forFile: false, loginItem: false, noBottles: true, busy: false, showInDock: true) == .addVersion)
    }

    // MARK: one sheet at a time

    @Test func sheetsWaitAndTheLastWins() {
        var q = SheetQueue<String>()
        q.show("plan"); #expect(q.shown == "plan")
        q.show("wizard"); q.show("signin"); #expect(q.shown == "plan"); #expect(q.queued == "signin")
        q.dropped(); #expect(q.shown == nil); #expect(q.busy)          // SwiftUI wrote nil: still on screen until onDismiss
        q.show("late"); #expect(q.shown == nil); #expect(q.queued == "late")
        let t = q.gone(); #expect(t == nil); q.showQueued(); #expect(q.shown == "late")
    }

    @Test func aPageSheetHoldsTheQueue() {
        var q = SheetQueue<String>()
        q.localShown()                                   // New connection is open
        q.show("addVersion"); #expect(q.shown == nil)    // Add Revit version from the menu
        q.localGone(); #expect(q.shown == "addVersion")  // New connection closed: the wizard comes
    }

    @Test func aSheetsNextStepGoesFirst() {
        var q = SheetQueue<String>()
        var ran: [String] = []
        q.show("recover")
        #expect(q.close(then: { ran.append("rollback") }) == nil)
        q.show("addVersion")                             // came while Recover was closing
        let t = q.gone(); t?(); q.showQueued()
        #expect(ran == ["rollback"]); #expect(q.shown == "addVersion")
        var empty = SheetQueue<String>()
        #expect(empty.close(then: { ran.append("now") }) != nil)   // nothing shown: the step is handed back at once
    }
}
