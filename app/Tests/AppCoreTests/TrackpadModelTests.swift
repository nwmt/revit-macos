// The app's side of the trackpad helper (spec §1–2, plan task 8): the switch, starting and replacing the helper,
// unexpected exits, the permission line. Fake launcher, fake permission reset, an instant clock.
import Foundation
import Testing
@testable import AppCore
import TrackpadState

@MainActor final class TrackpadWorld {
    let launcher = FakeHelperLauncher(), resetter = FakeResetter()
    let defaults = UserDefaults(suiteName: "trackpad-\(UUID().uuidString)")!
    let data = tempDir()
    var placement = "ok"
    var slept: [Double] = []
    var holdSleep = false
    private var sleepGate: CheckedContinuation<Void, Never>?
    var sleeping: Bool { sleepGate != nil }
    func releaseSleep() { holdSleep = false; sleepGate?.resume(); sleepGate = nil }
    lazy var model = TrackpadModel(launcher: launcher, resetter: resetter, defaults: defaults,
                                   engine: URL(fileURLWithPath: "/e/revit"), data: { [unowned self] in self.data },
                                   placement: { [unowned self] in self.placement }, parent: { (77, "Mon Oct 26 10:00:00 2026") },
                                   helperID: "io.example.testapp.trackpad", sleep: { @MainActor [unowned self] s in
                                       self.slept.append(s)
                                       if self.holdSleep { await withCheckedContinuation { self.sleepGate = $0 } }
                                   })
    func state(_ h: HelperInstance, trusted: Bool = true, tap: Bool = true, error: String? = nil, session: String? = nil) {
        let s = HelperState(session: session ?? launcher.launched.last!.session, pid: h.pid, start: h.start, trusted: trusted,
                            posting: tap, tap: tap, error: error, restart: nil, bottles: [:])
        try! StateFile.write(s, to: data.appending(path: "trackpad/state.json"))
    }
}

@MainActor @Test func defaultOff() async {
    let w = TrackpadWorld()
    await w.model.start()
    #expect(!w.model.enabled); #expect(w.model.line == .off); #expect(w.launcher.calls.isEmpty)
}

@MainActor @Test func enableLaunchesWithArgs() async {
    let w = TrackpadWorld()
    await w.model.setEnabled(true)
    let a = w.launcher.launched.last!
    #expect(a.parentPid == 77); #expect(a.parentStart == "Mon Oct 26 10:00:00 2026")
    #expect(a.engine.path == "/e/revit"); #expect(a.data == w.data); #expect(!a.recover && !a.recoverOnly); #expect(!a.session.isEmpty)
    #expect(w.model.line == .starting)
    w.state(w.launcher.instances[0]); w.model.refresh()
    #expect(w.model.line == .on)
    #expect(w.defaults.bool(forKey: "trackpadEnabled"))
}

@MainActor @Test func startWithTheSwitchOnLaunches() async {
    let w = TrackpadWorld(); w.defaults.set(true, forKey: "trackpadEnabled")
    await w.model.start()
    #expect(w.launcher.calls == ["launch"])
}

@MainActor @Test func replaceWaitsForExit() async {
    let w = TrackpadWorld(); w.launcher.instances = [HelperInstance(pid: 5, start: "old")]; w.launcher.quitsOnTerminate = false
    await w.model.setEnabled(true)
    #expect(w.launcher.calls == ["terminate 5", "force 5", "launch"])
}

@MainActor @Test func replaceGivesUpWhenOldStays() async {
    let w = TrackpadWorld(); w.launcher.instances = [HelperInstance(pid: 5, start: "old")]
    w.launcher.quitsOnTerminate = false; w.launcher.quitsOnForce = false
    await w.model.setEnabled(true)
    #expect(w.launcher.calls == ["terminate 5", "force 5"])
    if case .error = w.model.line {} else { Issue.record("want an error, got \(w.model.line)") }
}

@MainActor @Test func unexpectedExitRestartsWithRecover() async {
    let w = TrackpadWorld()
    await w.model.setEnabled(true)
    let h = w.launcher.instances[0]
    w.state(h)                                   // a fresh state of that very helper does not make the exit expected
    w.launcher.gone(h); await w.model.helperExited(h)
    #expect(w.launcher.calls == ["launch", "launch recover"]); #expect(w.slept.contains(10))
}

@MainActor @Test func expectedExitNoRestart() async {
    let w = TrackpadWorld()
    await w.model.setEnabled(true)
    let h = w.launcher.instances[0]
    await w.model.setEnabled(false)
    await w.model.helperExited(h)
    #expect(w.launcher.calls == ["launch", "terminate \(h.pid)"]); #expect(w.model.line == .off)
}

@MainActor @Test func threeCrashesError() async {
    let w = TrackpadWorld()
    await w.model.setEnabled(true)
    for _ in 0..<3 { let h = w.launcher.instances.last!; w.launcher.gone(h); await w.model.helperExited(h) }
    #expect(w.launcher.calls == ["launch", "launch recover", "launch recover"])
    if case .error = w.model.line {} else { Issue.record("want an error, got \(w.model.line)") }
}

@MainActor @Test func crashThenDisableRecoverOnly() async {
    let w = TrackpadWorld()
    await w.model.setEnabled(true)
    let h = w.launcher.instances[0]
    await w.model.setEnabled(false)                       // the switch goes off while the crash is not known yet
    w.launcher.calls.removeAll()
    w.launcher.gone(h); await w.model.helperExited(h)     // an exit we asked for: nothing
    #expect(w.launcher.calls.isEmpty)
    await w.model.setEnabled(true)
    let g = w.launcher.instances.last!
    w.launcher.calls.removeAll()
    w.model.enabledForTest(false)                         // off between the crash and its restart
    w.launcher.gone(g); await w.model.helperExited(g)
    #expect(w.launcher.calls == ["launch recover-only"])
}

@MainActor @Test func disableWhileWaitingPermission() async {
    let w = TrackpadWorld()
    await w.model.setEnabled(true)
    let h = w.launcher.instances[0]
    w.state(h, trusted: false, tap: false); w.model.refresh()
    #expect(w.model.line == .waiting(section: "Device Control and Data Access"))
    await w.model.setEnabled(false); await w.model.helperExited(h)
    #expect(w.model.line == .off); #expect(w.launcher.calls == ["launch", "terminate \(h.pid)"])
}

@MainActor @Test func offDuringLaunch() async {
    let w = TrackpadWorld(); w.launcher.holding = true
    let m = w.model
    let t = Task { await m.setEnabled(true) }
    while w.launcher.launched.isEmpty { await Task.yield() }
    await m.setEnabled(false)
    w.launcher.release(); await t.value
    #expect(w.launcher.instances.isEmpty)                 // the late helper was ended at once
    #expect(w.launcher.calls == ["launch", "terminate 901"]); #expect(m.line == .off)
}

@MainActor @Test func offOnDuringLaunch() async {
    let w = TrackpadWorld(); w.launcher.holding = true
    let m = w.model
    let t1 = Task { await m.setEnabled(true) }
    while w.launcher.launched.isEmpty { await Task.yield() }
    await m.setEnabled(false)
    w.launcher.holding = false
    let t2 = Task { await m.setEnabled(true) }
    w.launcher.release(); await t1.value; await t2.value
    #expect(w.launcher.instances.count == 1); #expect(m.enabled)
}

@MainActor @Test func offDuringAskAgain() async {
    let w = TrackpadWorld()
    await w.model.setEnabled(true)
    w.launcher.holding = true
    let m = w.model
    let t = Task { await m.askAgain() }
    while w.launcher.launched.count < 2 { await Task.yield() }
    await m.setEnabled(false)
    w.launcher.release(); await t.value
    #expect(w.launcher.instances.isEmpty); #expect(m.line == .off)
}

@MainActor @Test func askAgainOrder() async {
    let w = TrackpadWorld()
    await w.model.setEnabled(true)
    let h = w.launcher.instances[0]
    await w.model.askAgain()
    #expect(w.launcher.calls == ["launch", "terminate \(h.pid)", "launch"])
    #expect(w.resetter.calls == ["io.example.testapp.trackpad"])
}

@MainActor @Test func askAgainResetFails() async {
    let w = TrackpadWorld(); w.resetter.ok = false
    await w.model.setEnabled(true)
    await w.model.askAgain()
    #expect(w.launcher.calls == ["launch", "terminate 901"]); #expect(w.model.line == .lostManual)
}

@MainActor @Test func stateOfOtherSessionIgnored() async {
    let w = TrackpadWorld()
    await w.model.setEnabled(true)
    w.state(w.launcher.instances[0], session: "someone else"); w.model.refresh()
    #expect(w.model.line == .starting)
}

@MainActor @Test func lostAfterTrusted() async {
    let w = TrackpadWorld()
    await w.model.setEnabled(true)
    let h = w.launcher.instances[0]
    w.state(h); w.model.refresh(); #expect(w.model.line == .on)
    w.state(h, trusted: false, tap: false); w.model.refresh(); #expect(w.model.line == .lost)
}

@MainActor @Test func errorFromTheHelper() async {
    let w = TrackpadWorld()
    await w.model.setEnabled(true)
    w.state(w.launcher.instances[0], error: "macOS turned the event tap off too often"); w.model.refresh()
    #expect(w.model.line == .error("macOS turned the event tap off too often"))
}

@MainActor @Test func notInApplicationsDisables() async {
    let w = TrackpadWorld(); w.placement = "move"
    await w.model.setEnabled(true)
    #expect(w.launcher.calls.isEmpty); #expect(w.model.line == .notInApplications)
}

@Test func menuShowsTrackpadTrouble() throws {
    let s = try EngineStatus.decode(try Data(contentsOf: fixture("json/status-clone.json")))
    for (line, shown) in [(TrackpadLine.waiting(section: "x"), true), (.lost, true), (.lostManual, true), (.error("e"), true),
                          (.off, false), (.on, false), (.starting, false), (.notInApplications, false)] {
        let m = MenuContent.make(status: s, watched: nil, failure: nil, busy: false, trackpad: line)
        #expect((m.trackpad != nil) == shown, "\(line)")
    }
}

// final review 7: the restart after a crash waits 10 s; a helper started meanwhile is not replaced by it
@MainActor @Test func staleCrashRestartLeavesTheNewHelper() async {
    let w = TrackpadWorld(); let m = w.model
    await m.setEnabled(true)
    let h = w.launcher.instances[0]
    w.holdSleep = true
    w.launcher.gone(h)
    let t = Task { await m.helperExited(h) }
    while !w.sleeping { await Task.yield() }
    await m.setEnabled(false)
    w.holdSleep = false
    await m.setEnabled(true)                              // a new helper: it lets the button go itself
    w.releaseSleep(); await t.value
    #expect(w.launcher.calls == ["launch", "launch recover"]); #expect(w.launcher.instances.count == 1)
}

// final review 8: a launch that fails after the switch went off leaves "off"
@MainActor @Test func lateLaunchFailureKeepsOff() async {
    let w = TrackpadWorld(); w.launcher.holding = true; w.launcher.failLaunch = true
    let m = w.model
    let t = Task { await m.setEnabled(true) }
    while w.launcher.launched.isEmpty { await Task.yield() }
    await m.setEnabled(false)
    w.launcher.release(); await t.value
    #expect(m.line == .off)
}
