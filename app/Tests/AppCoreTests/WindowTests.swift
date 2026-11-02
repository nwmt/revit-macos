// The main window's models: the tabs, the cards, the drafts behind Apply, the plans the sheets compare, Activity.
import Foundation
import Testing
@testable import AppCore

let settings2027 = ["retina": "on", "keys": "mac", "theme": "mac", "steel": "on", "gdrive": "auto"]

func bottle(_ name: String = "rvt2027-a", _ year: String = "2027", running: Bool = false, settings: [String: String] = settings2027,
            support: Support? = Support(status: "works", tested: "2027.3", gaps: "Gaps")) -> Bottle {
    Bottle(name: name, year: year, revit: true, running: running, revitPids: running ? [7] : [], addins: [], support: support, settings: settings)
}

func windowStatus(_ bottles: String, points: String = "") throws -> EngineStatus {
    let s = """
    {"crossover":{"found":true,"path":"/x","version":"26.3","supported":true},"rosetta":true,"msls31":true,
     "busy":{"busy":false,"command":"","run_id":"","pid":"","pid_start":"","pgid":"","ctx":""},
     "shims_now":"0.16.0","restore_points":[\(points)],"bottles":[\(bottles)]}
    """
    return try EngineStatus.decode(Data(s.utf8))
}

let point2027 = #"{"bottle":"rvt2027-a","year":"2027","id":"20261030-100000","time":"2026-10-30T10:00:00Z","bytes":13000000000}"#
let pointGone = #"{"bottle":"rvt2024-a","year":"2024","id":"20261001-100000","time":"2026-10-01T10:00:00Z","bytes":9}"#
let bottle2027 = #"{"name":"rvt2027-a","year":"2027","revit":true,"running":false,"addins":[],"support":{"status":"works","tested":"2027.3","gaps":"Slow first"},"settings":{"retina":"on","steel":"off","gdrive":"auto"},"built":{"shims":"0.15.0","engine":"app:0.1.3","time":"t"},"gdrive":{"mode":"auto","mapping":"ok","accounts":"one","names":0,"settings":true,"names_kind":"en"}}"#

@Test func statusOfThisEngineDecodes() throws {
    let s = try windowStatus(bottle2027, points: point2027)
    let b = s.bottles[0]
    #expect(b.support?.tested == "2027.3"); #expect(b.settings["steel"] == "off"); #expect(b.built?.shims == "0.15.0")
    #expect(b.gdrive?.namesKind == "en"); #expect(s.shimsNow == "0.16.0"); #expect(s.restorePoints.first?.bytes == 13_000_000_000)
}

@Test func statusOfAnOlderEngineDecodes() throws {
    let s = try EngineStatus.decode(Data(contentsOf: fixture("json/status-app.json")))
    #expect(s.restorePoints.isEmpty); #expect(s.shimsNow == nil); #expect(s.bottles[0].support == nil); #expect(s.bottles[0].settings.isEmpty)
}

@Test func tabsFollowTheProfile() {
    #expect(VersionTab.of(bottle()) == [.overview, .display, .drive, .addins, .ai, .maintenance])
    #expect(VersionTab.of(bottle("rvt2020-a", "2020", settings: ["retina": "on", "keys": "mac", "gdrive": "auto"])) == [.overview, .display, .drive, .addins, .ai, .maintenance])
    #expect(VersionTab.of(bottle("rvt2025-a", "2025", settings: ["gdrive": "auto"])) == [.overview, .drive, .addins, .ai, .maintenance])
    #expect(VersionTab.of(bottle("x", "2025", settings: [:], support: nil)) == [.overview, .addins, .ai, .maintenance])
}

@Test func pointTimes() {
    #expect(PointTime.text("not a date") == "not a date")
    #expect(PointTime.text("2026-10-31T12:00:00Z").contains("2026"))
}

@Test func statusWords() {
    #expect(StatusWords.of("works") == "Works"); #expect(StatusWords.of("mostly") == "Mostly works")
    #expect(StatusWords.of("untested") == "Not tested"); #expect(StatusWords.of(nil) == "Not tested")
}

@Test func fixesLineComparesOnlyReleasesUpwards() {
    let b = { Built(shims: $0, engine: "", time: "") }
    #expect(FixesLine.of(built: nil, now: "0.16.0") == .unknown)
    #expect(FixesLine.of(built: b(""), now: "0.16.0") == .unknown)
    #expect(FixesLine.of(built: b("0.15.0"), now: "0.15.0") == .built("0.15.0"))
    #expect(FixesLine.of(built: b("0.9.0"), now: "0.10.0") == .newer(built: "0.9.0", now: "0.10.0"))
    #expect(FixesLine.of(built: b("0.16.0"), now: "0.15.0") == .built("0.16.0"))   // an older app says nothing
    #expect(FixesLine.of(built: b("source:abc"), now: "0.15.0") == .built("source:abc"))
    #expect(FixesLine.of(built: b("0.15.0"), now: "source:abc") == .built("0.15.0"))
}

@Test func settingsDraftSendsOnlyWhatChanged() {
    var d = SettingsDraft(settings2027)
    #expect(d.changes.isEmpty); #expect(!d.canApply(running: false, busy: false))
    d.picked["retina"] = "off"; d.picked["keys"] = "windows"
    #expect(d.changes == ["retina=off", "keys=windows"])
    #expect(d.canApply(running: false, busy: false)); #expect(!d.canApply(running: true, busy: false)); #expect(!d.canApply(running: false, busy: true))
    #expect(!d.needsSteelConfirm)
}

@Test func steelOffAlwaysAsksAndTheCostIsPlain() {
    var d = SettingsDraft(settings2027)
    d.picked["steel"] = "off"
    #expect(d.needsSteelConfirm); #expect(d.changes == ["steel=off"])
    #expect(SettingsDraft.steelCost(year: 2027).contains("steel connection tools")); #expect(SettingsDraft.steelCost(year: 2027).contains("1 of 7"))
    #expect(SettingsDraft.steelCost(year: 2020).contains("view with steel connections")); #expect(!SettingsDraft.steelCost(year: 2020).contains("1 of 7"))
    var on = SettingsDraft(["steel": "off"])
    on.picked["steel"] = "on"
    #expect(!on.needsSteelConfirm); #expect(on.changes == ["steel=on"])
    var mixed = SettingsDraft(["steel": "mixed", "retina": "mixed"])
    #expect(mixed.changes.isEmpty)
    mixed.picked["retina"] = "on"; mixed.picked["steel"] = "on"
    #expect(mixed.changes == ["retina=on", "steel=on"])
}

@Test func gdriveDraft() {
    var d = GDriveDraft(GDriveState(mode: "auto", mapping: "ok", accounts: "one", namesKind: "en"))
    #expect(d.changes.isEmpty)
    d.picked = "off"; #expect(d.changes == ["gdrive=off"])
    d.picked = "account"; #expect(d.needsEmail); #expect(!d.canApply(running: false, busy: false))
    d.email = "not an address"; #expect(d.changes.isEmpty)
    d.email = "a@example.com"; #expect(d.changes == ["gdrive=a@example.com"]); #expect(d.canApply(running: false, busy: false))
    d.russian = true; #expect(d.changes == ["gdrive=a@example.com", "gdrive_names=ru"])
    var r = GDriveDraft(GDriveState(mode: "account", mapping: "ok", accounts: "several", namesKind: "ru"))
    #expect(r.changes.isEmpty); r.russian = false; #expect(r.changes == ["gdrive_names=en"]); #expect(r.canApply(running: false, busy: false))
    var c = GDriveDraft(GDriveState(mode: "auto", mapping: "ok", accounts: "one", namesKind: "custom"))
    #expect(!c.showsNames); c.russian = true; #expect(c.changes.isEmpty)   // own names stay
}

@Test func launchPicksOneWindow() {
    func p(active: Bool = false, file: Bool = false, login: Bool = false, none: Bool = false, busy: Bool = false, dock: Bool = true) -> LaunchRoute {
        LaunchRoute.pick(activeRun: active, forFile: file, loginItem: login, noBottles: none, busy: busy, showInDock: dock)
    }
    #expect(p() == .main); #expect(p(active: true, file: true, login: true) == .activity); #expect(p(file: true, none: true) == .nothing)
    #expect(p(none: true) == .addVersion); #expect(p(login: true, none: true) == .nothing); #expect(p(none: true, busy: true) == .main)
    #expect(p(login: true) == .nothing); #expect(p(dock: false) == .nothing); #expect(p(none: true, dock: false) == .addVersion)
}

@Test func libraryCardsAndPointsOfBottlesGone() throws {
    let c = LibraryContent.make(status: try windowStatus(bottle2027, points: point2027 + "," + pointGone), watched: nil, starting: ["rvt2027-a"])
    #expect(c.cards.count == 1)
    let k = c.cards[0]
    #expect(k.status == "works"); #expect(k.note == "Slow first"); #expect(k.hasPoint); #expect(k.starting); #expect(!k.taskHere)
    #expect(c.orphans == [OrphanPoints(bottle: "rvt2024-a", year: 2024, points: [RestorePoint(bottle: "rvt2024-a", year: "2024", id: "20261001-100000", time: "2026-10-01T10:00:00Z", bytes: 9)])])
}

@Test func aCardSaysWhatRunsInItsBottle() throws {
    let w = run(.set(year: 2027, bottle: "rvt2027-a", settings: ["retina=off"]), events: [.start(runID: "a", command: "set", year: 2027, bottle: "rvt2027-a", pid: 1)])
    let k = LibraryContent.make(status: try windowStatus(bottle2027), watched: w, starting: []).cards[0]
    #expect(k.taskHere); #expect(k.note == "Changing settings of Revit 2027")
}

@Test func newRunsAndTheirArguments() {
    #expect(RunRequest.set(year: 2027, bottle: "b", settings: ["steel=off"]).arguments == ["set", "2027", "b", "steel=off"])
    #expect(RunRequest.rollback(year: 2027, bottle: "b", id: "1").arguments == ["rollback", "2027", "b", "--yes", "--to", "1"])
    #expect(RunRequest.clearPoints(year: 2027, bottle: "b", ids: ["1", "2"], clearUnfinished: true).arguments
            == ["points", "2027", "b", "--yes", "--clear-ids", "1,2", "--clear-unfinished"])
    #expect(RunRequest.clearPoints(year: 2027, bottle: "b", ids: [], clearUnfinished: true).arguments == ["points", "2027", "b", "--yes", "--clear-unfinished"])
    for r in [RunRequest.set(year: 2027, bottle: "b", settings: []), .rollback(year: 2027, bottle: "b", id: "1"), .clearPoints(year: 2027, bottle: "b", ids: [], clearUnfinished: false)] {
        #expect(!r.cancellable)
    }
    #expect(RunRequest.remove(year: 2027, bottle: "b").needsSheet); #expect(RunRequest.rollback(year: 2027, bottle: "b", id: "1").needsSheet)
    #expect(RunRequest.rebuild(year: 2027, bottle: "b", source: nil).needsSheet); #expect(!RunRequest.set(year: 2027, bottle: "b", settings: []).needsSheet)
}

@Test func anAddressIsNeverWrittenDown() throws {
    let r = RunRequest.set(year: 2027, bottle: "b", settings: ["gdrive=a@example.com", "retina=on"])
    #expect(r.persistable == .set(year: 2027, bottle: "b", settings: ["gdrive=account", "retina=on"]))
    #expect(r.persistable.lostAddress); #expect(!r.lostAddress)
    #expect(RunRequest.set(year: 2027, bottle: "b", settings: ["gdrive=auto"]).persistable == .set(year: 2027, bottle: "b", settings: ["gdrive=auto"]))
    let d = try JSONEncoder().encode(RunRecord(ctx: "c", runID: "r", request: r.persistable, pid: 1, pidStart: "s"))
    #expect(!String(decoding: d, as: UTF8.self).contains("example.com"))
}

@Test func plansDifferByWhatHappensNotBySize() throws {
    func remove(_ s: String) throws -> RemovePlan { try JSONDecoder.engine.decode(RemovePlan.self, from: Data(s.utf8)) }
    let a = try remove(#"{"command":"rebuild","year":2027,"bottle":"b","delete":[{"label":"bottle b","bytes":100}],"addins_reset":true,"restore_point":true,"notes":["n"]}"#)
    let bigger = try remove(#"{"command":"rebuild","year":2027,"bottle":"b","delete":[{"label":"bottle b","bytes":900}],"addins_reset":true,"restore_point":true,"notes":["n"]}"#)
    let noPoint = try remove(#"{"command":"rebuild","year":2027,"bottle":"b","delete":[{"label":"bottle b","bytes":100}],"addins_reset":true,"restore_point":false,"notes":["n"]}"#)
    let notes = try remove(#"{"command":"rebuild","year":2027,"bottle":"b","delete":[{"label":"bottle b","bytes":100}],"addins_reset":true,"restore_point":true,"notes":["m"]}"#)
    #expect(a.fingerprint == bigger.fingerprint); #expect(a.fingerprint != noPoint.fingerprint); #expect(a.fingerprint != notes.fingerprint)
    func roll(_ e: Bool) throws -> RollbackPlan { try JSONDecoder.engine.decode(RollbackPlan.self, from: Data(#"{"command":"rollback","year":2027,"bottle":"b","id":"1","time":"t","bytes":1,"bottle_exists":\#(e)}"#.utf8)) }
    #expect(try roll(true).fingerprint != roll(false).fingerprint)
    func pts(_ ids: String) throws -> PointsPlan { try JSONDecoder.engine.decode(PointsPlan.self, from: Data(#"{"command":"points","year":2027,"bottle":"b","delete":[],"ids":[\#(ids)],"unfinished":false}"#.utf8)) }
    #expect(try pts(#""1""#).fingerprint != pts(#""1","2""#).fingerprint)
}

@Test func theGateOpensForTheYearOnly() {
    var g = SheetGate(year: 2027)
    #expect(!g.open); g.typed = "2026"; #expect(!g.open); g.typed = " 2027 "; #expect(g.open); g.reset(); #expect(!g.open)
    #expect(SheetGate(year: nil).open)
}

@Test func activityReadsPastRuns() throws {
    let d = tempDir()
    func runDir(_ n: String, _ lines: [String]) {
        try! FileManager.default.createDirectory(at: d.appending(path: n), withIntermediateDirectories: true)
        append(d.appending(path: n).appending(path: "events.ndjson"), lines.map { $0 + "\n" }.joined())
    }
    let start = #"{"event":"start","run_id":"x","command":"set","year":2027,"bottle":"rvt2027-a","pid":1}"#
    runDir("a", [start, #"{"event":"end","exit_code":0,"result":"ok","failed_action":"","failed_steps":[],"log_dir":""}"#])
    runDir("b", [start, #"{"event":"end","exit_code":1,"result":"failed","failed_action":"","failed_steps":[],"log_dir":""}"#])
    runDir("c", [start])
    runDir("d", [start])
    runDir("e", ["not json"])
    try FileManager.default.createDirectory(at: d.appending(path: "f"), withIntermediateDirectories: true)
    let rows = ActivityLog.load(runs: d, active: URL(fileURLWithPath: "/private" + d.path).appending(path: "d"))   // the same run by another path
    func of(_ n: String) -> RunRow? { rows.first { $0.ctx.lastPathComponent == n } }
    #expect(rows.count == 4)
    #expect(of("a")?.outcome == .done); #expect(of("b")?.outcome == .failed); #expect(of("c")?.outcome == .interrupted); #expect(of("d")?.outcome == .running)
    #expect(of("a")?.title == "Changing settings of Revit 2027"); #expect(of("a")?.bottle == "rvt2027-a")
    #expect(ActivityLog.load(runs: d.appending(path: "none"), active: nil).isEmpty)
    #expect(ActivityLog.load(runs: d, active: nil, limit: 2).count == 2)
}

func bottleStatus(running: Bool) -> EngineOutput {
    let b = #"{"name":"rvt2027-a","year":"2027","revit":true,"running":\#(running),"revit_pids":[\#(running ? "7" : "")],"addins":[]}"#
    let json = #"{"crossover":{"found":true,"path":"/x","version":"26.3","supported":true},"rosetta":true,"msls31":true,"busy":{"busy":false,"command":"","run_id":"","pid":"","pid_start":"","pgid":"","ctx":""},"bottles":[\#(b)]}"#
    return EngineOutput(stdout: Data(json.utf8), stderr: "", exitCode: 0)
}

@MainActor @Suite(.serialized) struct OpenRevitTests {
    let ok = EngineOutput(stdout: Data(), stderr: "", exitCode: 0)

    @Test func twoPressesStartOneRevit() async {
        let h = Harness()
        await h.fake.setStatus([bottleStatus(running: false)])
        await h.fake.set(query: ["start", "2027", "rvt2027-a"], ok)
        async let first = h.model.open(year: 2027, bottle: "rvt2027-a")
        async let second = h.model.open(year: 2027, bottle: "rvt2027-a")
        let r = await [first, second]
        #expect(r == [.starting, .starting])
        #expect(await h.fake.calls.filter { $0.hasPrefix("run start") }.count == 1)
        #expect(h.model.revitStarting["rvt2027-a"] != nil)
    }

    @Test func aRunningRevitIsShownNotStarted() async {
        let h = Harness()
        await h.fake.setStatus([bottleStatus(running: true)])
        #expect(await h.model.open(year: 2027, bottle: "rvt2027-a") == .running([7]))
        #expect(await !h.fake.calls.contains { $0.hasPrefix("run start") })
        #expect(h.model.revitStarting.isEmpty)
    }

    @Test func aRefusalSaysWhyAndFrees() async {
        let h = Harness()
        await h.fake.setStatus([bottleStatus(running: false)])
        await h.fake.set(query: ["start", "2027", "rvt2027-a"], EngineOutput(stdout: Data(), stderr: "Another task\n", exitCode: 75))
        #expect(await h.model.open(year: 2027, bottle: "rvt2027-a") == .refused("Another task"))
        #expect(h.model.revitStarting.isEmpty)
    }

    @Test func theMarkGoesWhenRevitIsUpOrTimeIsOut() async {
        let h = Harness()
        await h.fake.setStatus([bottleStatus(running: false)])
        await h.fake.set(query: ["start", "2027", "rvt2027-a"], ok)
        _ = await h.model.open(year: 2027, bottle: "rvt2027-a")
        h.model.expireStarting(now: Date().addingTimeInterval(170)); #expect(!h.model.revitStarting.isEmpty)
        h.model.expireStarting(now: Date().addingTimeInterval(181)); #expect(h.model.revitStarting.isEmpty)
        _ = await h.model.open(year: 2027, bottle: "rvt2027-a")
        await h.fake.setStatus([bottleStatus(running: true)])
        await h.model.refresh()
        #expect(h.model.revitStarting.isEmpty)
    }

    @Test func anAddressStaysInMemoryAndRetryIsGoneAfterARestart() async throws {
        let h = Harness()
        await h.fake.setStatus([statusOut(appData: h.data.path)])
        await h.model.refresh()
        let r = RunRequest.set(year: 2027, bottle: "b", settings: ["gdrive=a@example.com"])
        try await h.model.start(r)
        #expect(h.model.retryRequest == r)
        #expect(await h.fake.started.last?.contains("gdrive=a@example.com") == true)
        let saved = h.defaults.data(forKey: "lastRun").map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(!saved.isEmpty); #expect(!saved.contains("example.com"))
        await h.fake.emit([endOK]); await h.model.poll()
        #expect(!h.notifier.posts.description.contains("example.com"))
        let again = h.newModel()
        h.save(RunRecord(ctx: h.ctx.path, runID: h.runID, request: r.persistable, pid: 4242, pidStart: FakeEngine.startTime))
        await h.fake.setStarts([4242: FakeEngine.startTime])
        await again.launch()
        #expect(again.watched?.record?.request.lostAddress == true); #expect(again.retryRequest == nil)
    }
}

@MainActor @Test func theViewerGoesThroughTheSameStart() async {
    let h = Harness()
    await h.fake.set(query: ["start", "2020", "b", "--viewer"], EngineOutput(stdout: Data(), stderr: "", exitCode: 0))
    #expect(await h.model.open(year: 2020, bottle: "b", viewer: true) == .starting)
    #expect(await h.model.open(year: 2020, bottle: "b") == .starting)
    #expect(await h.fake.calls.filter { $0.hasPrefix("run start") } == ["run start 2020 b --viewer"])
}
