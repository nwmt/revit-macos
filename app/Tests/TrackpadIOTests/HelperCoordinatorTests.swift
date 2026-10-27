// The trackpad helper's coordinator (spec §1–4, §7; plan task 7) with fake ports and a fake clock.
import CoreGraphics
import Foundation
import Testing
@testable import TrackpadCore
@testable import TrackpadIO
import TrackpadState

@MainActor @Test func promptOnceAtStart() async {
    let w = World(); let c = w.coordinator()
    await c.start(); await c.checkPermission(); await c.checkPermission()
    #expect(w.perm.prompts == 1)
}

@MainActor @Test func tapOnlyWhenTrustedAndRevit() async {
    let w = World(); w.perm.isTrusted = false; let c = w.coordinator()
    await c.start()
    #expect(!w.j.lines.contains("create"))
    w.perm.isTrusted = true; await c.checkPermission()
    #expect(!w.j.lines.contains("create"))                 // no Revit yet
    w.revit(500); await c.revitLaunched(500)
    #expect(w.j.lines.contains("create")); #expect(w.state.states.last?.tap == true); #expect(w.state.states.last?.posting == true)
    await c.revitTerminated(500)
    #expect(w.j.lines.last == "cancelAndDisable switchOff"); #expect(w.state.states.last?.tap == false)
}

@MainActor @Test func postingProbeFailsRestarts() async {
    let w = World(); w.tap.probeOK = false; w.revit(500); let c = w.coordinator()
    await c.start()
    #expect(w.j.lines.suffix(3) == ["create", "probe", "disable"])
    #expect(w.state.states.last?.restart != nil); #expect(c.exited)
}

@MainActor @Test func tapCreateRefusedRestarts() async {
    let w = World(); w.tap.createOK = false; w.revit(500); let c = w.coordinator()
    await c.start()
    #expect(w.state.states.last?.restart != nil); #expect(c.exited)
}

@MainActor @Test func permissionRevokedCancelsAndDisables() async {
    let w = World(); w.revit(500); let c = w.coordinator()
    await c.start()
    w.perm.isTrusted = false; await c.checkPermission()
    #expect(w.j.lines.last == "cancelAndDisable permissionLost")   // one step on the tap's thread (final review 1)
    #expect(w.state.states.last?.trusted == false); #expect(w.state.states.last?.tap == false)
    w.perm.isTrusted = true; await c.checkPermission()
    #expect(w.j.lines.last == "probe"); #expect(w.state.states.last?.tap == true)
}

@MainActor @Test func recoverPostsUpBeforeTap() async {
    let w = World(); w.revit(500); let c = w.coordinator(recover: true)
    await c.start()
    #expect(w.j.lines.first == "post \(Post.up(CGPoint(x: 5, y: 6), []))")
    #expect(w.j.lines.firstIndex(of: "create")! > 0)
}

@MainActor @Test func recoverOnlyPostsUpAndExits() async {
    let w = World(); w.revit(500); let c = w.coordinator(recoverOnly: true)
    await c.start()
    #expect(w.j.lines == ["post \(Post.up(CGPoint(x: 5, y: 6), []))"]); #expect(c.exited); #expect(w.perm.prompts == 0)
}

@MainActor @Test func recoverOnlyUntrustedDoesNothing() async {
    let w = World(); w.perm.isTrusted = false; let c = w.coordinator(recoverOnly: true)
    await c.start()
    #expect(w.j.lines.isEmpty); #expect(c.exited)
}

@MainActor @Test func revitQuitDuringPanCancelsFirst() async {
    let w = World(); w.revit(500); let c = w.coordinator()
    await c.start()
    w.tap.cancelDelay = 50_000_000
    await c.revitTerminated(500)
    let i = w.j.lines.firstIndex(of: "cancelled targetGone(500)"), s = w.j.lines.firstIndex(of: "stop rvt2027-a")
    #expect(i != nil && s != nil && i! < s!)
}

@MainActor @Test func shutdownWaitsForCancel() async {
    let w = World(); w.revit(500); let c = w.coordinator()
    await c.start()
    w.tap.cancelDelay = 50_000_000
    await c.shutdown(reason: "test")
    let i = w.j.lines.firstIndex(of: "cancelAndDisable switchOff"), s = w.j.lines.firstIndex(of: "shutdown rvt2027-a")
    #expect(i != nil && s != nil && i! < s!); #expect(c.exited)
}

@MainActor @Test func decideRoutesTwoBottles() {
    let j = Journal()
    let a = FakeClient("rvt2027-a", j), b = FakeClient("rvt2027-b", j)
    a.status = .ready(scale: 2); b.status = .ready(scale: 1)
    let view = HitReply(seq: 1, chain: [HitWindow(cls: "AfxFrameOrView140u", title: ""), HitWindow(cls: "F", title: "Floor Plan: L1")], complete: true, bad: false)
    a.reply = view; b.reply = view
    let ctx = DecideContext(revits: [500: RevitTarget(bottle: "rvt2027-a", year: 2027, client: a),
                                     600: RevitTarget(bottle: "rvt2027-b", year: 2027, client: b)])
    let wins = [WinInfo(pid: 500, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), alpha: 1),
                WinInfo(pid: 600, bounds: CGRect(x: 600, y: 0, width: 500, height: 500), alpha: 1)]
    #expect(Decider.decide(at: CGPoint(x: 100, y: 50), windows: wins, buttonsDown: false, context: ctx) == Target(pid: 500))
    #expect(a.asked == [WinePoint(x: 200, y: 100)])
    #expect(Decider.decide(at: CGPoint(x: 700, y: 50), windows: wins, buttonsDown: false, context: ctx) == Target(pid: 600))
    #expect(b.asked == [WinePoint(x: 700, y: 50)])
    b.status = .starting
    #expect(Decider.decide(at: CGPoint(x: 700, y: 50), windows: wins, buttonsDown: false, context: ctx) == nil)
    #expect(Decider.decide(at: CGPoint(x: 100, y: 50), windows: wins, buttonsDown: true, context: ctx) == nil)
    a.reply = HitReply(seq: 1, chain: [HitWindow(cls: "GXWND", title: ""), HitWindow(cls: "F", title: "Properties")], complete: true, bad: false)
    #expect(Decider.decide(at: CGPoint(x: 100, y: 50), windows: wins, buttonsDown: false, context: ctx) == nil)
}

@MainActor @Test func twoBottlesTwoClients() async {
    let w = World(); let c = w.coordinator()
    w.ws.pids = [500, 600]
    w.engine.answers = [[EngineBottle(bottle: "rvt2027-a", year: 2027, pids: [500]), EngineBottle(bottle: "rvt2026-a", year: 2026, pids: [600])]]
    await c.start()
    #expect(Set(w.clients.made.keys) == ["rvt2027-a", "rvt2026-a"])
    #expect(w.tap.contexts.last?.revits.mapValues(\.bottle) == [500: "rvt2027-a", 600: "rvt2026-a"])
    #expect(w.tap.contexts.last?.revits[600]?.year == 2026)
}

@MainActor @Test func statusRetriesUntilPidAppears() async {
    let w = World(); let c = w.coordinator()
    await c.start()
    w.ws.pids = [500]
    w.engine.answers = [[], [], [EngineBottle(bottle: "rvt2027-a", year: 2027, pids: [500])]]
    await c.revitLaunched(500)
    #expect(w.clock.slept == [2, 5]); #expect(w.clients.made["rvt2027-a"] != nil)
    let v = World(); let d = v.coordinator(); await d.start()
    v.ws.pids = [700]; v.engine.answers = [[]]
    await d.revitLaunched(700)
    #expect(v.clock.slept == [2, 5, 10]); #expect(v.clients.made.isEmpty)
}

@MainActor @Test func displaysBlockUntilHelloMatches() async {
    let w = World(); w.revit(500); let c = w.coordinator()
    await c.start()
    let cl = w.clients.made["rvt2027-a"]!
    cl.status = .notReady("unknown display layout")
    await c.displaysChanged()
    #expect(w.j.lines.contains("cancel displays"))
    #expect(cl.restarts == 11)                          // at once, then every second, ten times
    #expect(w.clock.slept == Array(repeating: 1.0, count: 10))
    #expect(w.state.states.last?.bottles["rvt2027-a"]?.error == "unknown display layout")
    let v = World(); v.revit(500); let d = v.coordinator(); await d.start()
    let dl = v.clients.made["rvt2027-a"]!
    dl.status = .ready(scale: 2)
    await d.displaysChanged()
    #expect(dl.restarts == 1); #expect(v.clock.slept == [1])
}

@MainActor @Test func tapDisabledSixTimesError() async {
    let w = World(); w.revit(500); let c = w.coordinator()
    await c.start()
    for _ in 0..<5 { await c.tapDisabledByMacOS(); w.clock.t += 1 }
    #expect(w.state.states.last?.error == nil); #expect(w.j.lines.last != "cancelAndDisable tapDisabled")
    await c.tapDisabledByMacOS()
    #expect(w.state.states.last?.error != nil); #expect(w.j.lines.last == "cancelAndDisable tapDisabled")
    let v = World(); v.revit(500); let d = v.coordinator(); await d.start()
    for _ in 0..<10 { await d.tapDisabledByMacOS(); v.clock.t += 20 }   // spread over minutes: no error
    #expect(v.state.states.last?.error == nil)
}

@MainActor @Test func stateWrittenOnChange() async {
    let w = World(); w.revit(500); let c = w.coordinator()
    await c.start()
    let n = w.state.states.count
    await c.checkPermission(); await c.checkPermission()
    #expect(w.state.states.count == n)                   // nothing changed: nothing written
    let s = w.state.states.last!
    #expect(s.session == "s1"); #expect(s.pid == 4242); #expect(s.trusted); #expect(s.tap)
    #expect(s.bottles["rvt2027-a"] == BottleState(ready: true, error: nil))
}

@MainActor @Test func activationGoesToTheMachine() async {
    let w = World(); w.revit(500); let c = w.coordinator()
    await c.start(); await c.activated(77)
    #expect(w.j.lines.contains("cancelled activated(77)"))
}

@MainActor @Test func logHasNoTitlesOrCoordinates() async {
    let w = World(); w.revit(500); let c = w.coordinator()
    await c.start()
    let cl = w.clients.made["rvt2027-a"]!
    cl.reply = HitReply(seq: 1, chain: [HitWindow(cls: "AfxFrameOrView140u", title: "ProjectSecret-XYZ"),
                                        HitWindow(cls: "F", title: "ProjectSecret-XYZ Floor Plan")], complete: true, bad: false)
    let ctx = w.tap.contexts.last!
    let small = TrackpadLog(url: w.dir.appending(path: "logs/trackpad.log"), limit: 300)
    for _ in 0..<5 {
        _ = Decider.decide(at: CGPoint(x: 1234, y: 567), windows: [WinInfo(pid: 500, bounds: CGRect(x: 0, y: 0, width: 5000, height: 5000), alpha: 1)],
                           buttonsDown: false, context: ctx, log: small)
    }
    cl.status = .notReady("no answer twice"); await c.checkPermission(); await c.refreshBottles()
    small.flush(); w.log.flush()
    let files = ["logs/trackpad.log", "logs/trackpad.log.1"].map { (try? String(contentsOf: w.dir.appending(path: $0), encoding: .utf8)) ?? "" }
    #expect(files[0].contains("view AfxFrameOrView140u")); #expect(!files[1].isEmpty)
    let states = String(decoding: try! JSONEncoder().encode(w.state.states), as: UTF8.self)
    for text in files + [states] {
        #expect(!text.contains("ProjectSecret")); #expect(!text.contains("1234")); #expect(!text.contains("567"))
    }
}

@MainActor @Test func syncRevitsFollowsTheWorkspace() async {
    let w = World(); let c = w.coordinator()
    await c.start()
    w.revit(600); await c.syncRevits()
    #expect(w.clients.made["rvt2027-a"] != nil); #expect(w.j.lines.contains("create"))
    w.ws.pids = []; await c.syncRevits()
    #expect(w.j.lines.contains("stop rvt2027-a")); #expect(w.j.lines.last == "cancelAndDisable switchOff")
}

// final review 2: hittest failing during a gesture cancels it for that bottle's Revits
@MainActor @Test func hittestFailureCancelsTheBottlesGesture() async {
    let w = World(); w.revit(500); let c = w.coordinator()
    await c.start()
    let cl = w.clients.made["rvt2027-a"]!
    #expect(cl.watcher != nil)                           // the coordinator listens to the client
    cl.status = .notReady("no answer twice")
    await c.clientChanged(bottle: "rvt2027-a", cl.status)
    #expect(w.j.lines.contains("cancelled hittestFailed(500)"))
    #expect(w.state.states.last?.bottles["rvt2027-a"]?.error == "no answer twice")
    let n = w.j.lines.count
    cl.status = .ready(scale: 2); await c.clientChanged(bottle: "rvt2027-a", cl.status)
    #expect(w.j.lines.count == n)                        // ready again: nothing to cancel
}

// final review 6: the helper's own middle button does not count as a button held by the user
@Test func ownMiddleButtonIsNotAHeldButton() {
    #expect(!Decider.userButtonsDown(left: false, right: false, center: true, ownCenterDown: true))
    #expect(Decider.userButtonsDown(left: false, right: false, center: true, ownCenterDown: false))
    #expect(Decider.userButtonsDown(left: true, right: false, center: true, ownCenterDown: true))
    #expect(Decider.userButtonsDown(left: false, right: true, center: false, ownCenterDown: false))
    #expect(!Decider.userButtonsDown(left: false, right: false, center: false, ownCenterDown: false))
}

// final review 5: every display change cancels at once; one arriving while the first is handled runs it again
@MainActor @Test func displayChangesDuringOneAreTakenTogether() async {
    let w = World(); w.revit(500); let c = w.coordinator()
    await c.start()
    let cl = w.clients.made["rvt2027-a"]!
    w.tap.cancelDelay = 20_000_000
    let first = Task { await c.displaysChanged() }
    while !w.j.lines.contains("cancel displays") { await Task.yield() }
    await c.displaysChanged()                            // while the first one is still at work
    await first.value
    #expect(w.j.lines.filter { $0 == "cancelled displays" }.count == 2)
    #expect(cl.restarts == 2)                            // the second change made the clients start again once more
}

@MainActor @Test func blockForDisplaysCancelsAndStopsDecisionsAtOnce() async {
    let w = World(); w.revit(500); let c = w.coordinator()
    await c.start()
    await c.blockForDisplays()
    #expect(w.j.lines.last == "cancelled displays"); #expect(w.clients.made["rvt2027-a"]!.restarts == 1); #expect(w.clock.slept.isEmpty)
}
