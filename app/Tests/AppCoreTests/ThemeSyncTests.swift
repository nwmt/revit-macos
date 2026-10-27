// ThemeSync: which bottles it calls `theme` for, when, and that one failing bottle or a call on its way holds nothing up.
import Foundation
import Testing
@testable import AppCore

/// An engine that answers `theme` from a queue of exit codes (default 0) and can hold a call until released.
actor ThemeEngine: EngineClient {
    var calls: [[String]] = []
    var codes: [Int32] = []
    var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    var throwing = false

    func setCodes(_ c: [Int32]) { codes = c }
    func hold() { holding = true }
    func release() { holding = false; let h = held; held = []; for c in h { c.resume() } }
    func setThrowing(_ t: Bool) { throwing = t }
    var waiting: Int { held.count }

    func run(_ args: [String]) async throws -> EngineOutput {
        calls.append(args)
        if throwing { throw EngineStartError(description: "cannot start") }
        if holding { await withCheckedContinuation { held.append($0) } }
        let rc = codes.isEmpty ? 0 : codes.removeFirst()
        return EngineOutput(stdout: Data(), stderr: "", exitCode: rc)
    }
    func start(_ args: [String], ctx: URL) async throws -> Int32 { 0 }
    func interrupt(pid: Int32, pidStart: String) async -> Bool { false }
    func processStart(pid: Int32) async -> String? { nil }
    func isSessionLeader(_ pid: Int32) async -> Bool { false }
}

private func bottle(_ name: String, year: String = "2027", pids: [Int32] = [100], mode: String = "mac") -> Bottle {
    Bottle(name: name, year: year, revit: true, running: !pids.isEmpty, revitPids: pids, addins: [], themeMode: mode)
}

/// Kicks, then waits until the call it started has come back (or nothing was started).
@MainActor private func kickAndSettle(_ s: ThemeSync) async {
    s.kick()
    for _ in 0..<200 where s.active != nil { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor private func waitFor(_ cond: @escaping () async -> Bool) async {
    for _ in 0..<200 { if await cond() { return }; try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor @Test func onlyRevit2027BottlesThatFollowTheMacWithARevit() async {
    let e = ThemeEngine(), s = ThemeSync(engine: e)
    s.update(bottles: [bottle("a"), bottle("b", year: "2026"), bottle("c", pids: []), bottle("d", mode: "light"),
                       bottle("e", mode: "")])
    await kickAndSettle(s); await kickAndSettle(s)
    #expect(await e.calls == [["theme", "2027", "a"]])
}

@MainActor @Test func noCallAgainForTheSameLookAndRevit() async {
    let e = ThemeEngine(), s = ThemeSync(engine: e)
    s.update(bottles: [bottle("a")]); await kickAndSettle(s)
    s.update(bottles: [bottle("a")]); await kickAndSettle(s)
    #expect(await e.calls.count == 1)
    s.appearanceChanged(); await kickAndSettle(s)
    #expect(await e.calls.count == 2)
}

@MainActor @Test func aNewRevitProcessIsSynced() async {
    let e = ThemeEngine(), s = ThemeSync(engine: e)
    s.update(bottles: [bottle("a", pids: [100])]); await kickAndSettle(s)
    s.update(bottles: [bottle("a", pids: [200])]); await kickAndSettle(s)   // no empty list in between
    #expect(await e.calls.count == 2)
}

@MainActor @Test func aChangeDuringTheCallIsSyncedAfterIt() async {
    let e = ThemeEngine(), s = ThemeSync(engine: e)
    await e.hold()
    s.update(bottles: [bottle("a", pids: [100])]); s.kick()
    await waitFor { await e.waiting == 1 }
    s.update(bottles: [bottle("a", pids: [100, 101])]); s.appearanceChanged()
    s.kick()   // a call is on its way: nothing more
    #expect(await e.calls.count == 1)
    await e.release(); await waitFor { await MainActor.run { s.active == nil } }
    await kickAndSettle(s)
    #expect(await e.calls.count == 2)
    await kickAndSettle(s)
    #expect(await e.calls.count == 2)
}

@MainActor @Test func aBusyLockIsTriedOnEveryKickUntilItWorks() async {
    let e = ThemeEngine(), s = ThemeSync(engine: e)
    await e.setCodes([75, 75, 75, 0])
    s.update(bottles: [bottle("a")])
    for _ in 0..<6 { await kickAndSettle(s) }
    #expect(await e.calls.count == 4)
}

@MainActor @Test func aFailingBottleDoesNotHoldUpAnother() async {
    let e = ThemeEngine(), s = ThemeSync(engine: e)
    await e.setCodes([1, 0, 1, 1])
    s.update(bottles: [bottle("a"), bottle("b")])
    for _ in 0..<4 { await kickAndSettle(s) }
    let calls = await e.calls.map { $0[2] }
    #expect(calls.prefix(2) == ["a", "b"])
    #expect(s.targets["b"]?.done != nil); #expect(s.targets["a"]?.done == nil)
}

@MainActor @Test func aCallThatCannotStartIsTriedAgain() async {
    let e = ThemeEngine(), s = ThemeSync(engine: e)
    await e.setThrowing(true)
    s.update(bottles: [bottle("a")]); await kickAndSettle(s)
    await e.setThrowing(false); await kickAndSettle(s)
    #expect(await e.calls.count == 2); #expect(s.targets["a"]?.done != nil)
}

@MainActor @Test func kickNeverWaitsForTheCall() async {
    let e = ThemeEngine(), s = ThemeSync(engine: e)
    await e.hold()
    s.update(bottles: [bottle("a")])
    s.kick(); s.kick(); s.update(bottles: [bottle("a")])   // returns at once, one call
    await waitFor { await e.waiting == 1 }
    #expect(await e.calls.count == 1)
    await e.release()
}

@MainActor @Test func aBottleGoneAndBackDuringACallGetsNoSecondCallUntilItEnds() async {
    let e = ThemeEngine(), s = ThemeSync(engine: e)
    await e.hold()
    s.update(bottles: [bottle("a", pids: [100])]); s.kick()
    await waitFor { await e.waiting == 1 }
    s.update(bottles: [bottle("a", pids: [])])      // Revit gone: no longer a target
    s.update(bottles: [bottle("a", pids: [200])])   // a new Revit
    s.kick()
    #expect(await e.calls.count == 1)
    await e.release(); await waitFor { await MainActor.run { s.active == nil } }
    #expect(s.targets["a"]?.done == nil)            // the old call's success is not the new Revit's
    await kickAndSettle(s)
    #expect(await e.calls.count == 2); #expect(s.targets["a"]?.done != nil)
}

@Test func themeModeDecodes() throws {
    let j = #"{"crossover":{"found":true,"path":"/x","version":"26.3.0","supported":true},"rosetta":true,"msls31":false,"busy":{"busy":false,"command":"","run_id":"","pid":"","pid_start":"","pgid":"","ctx":""},"bottles":[{"name":"b","year":"2027","revit":true,"running":true,"revit_pids":[1],"addins":[],"theme_mode":"mac"},{"name":"c","year":"2024","revit":true,"running":false,"addins":[]}]}"#
    let s = try EngineStatus.decode(Data(j.utf8))
    #expect(s.bottles[0].themeMode == "mac"); #expect(s.bottles[1].themeMode == "")   // an older engine: no theme_mode
}
