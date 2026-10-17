// The app model against the Swift fake engine: starting runs, following their events, deciding when a run without an
// end is still finishing or was interrupted, reattaching after a restart, and when Cancel may send its signal.
import Foundation
import Testing
@testable import AppCore

@MainActor final class Harness {
    let fake = FakeEngine()
    let defaults = TestDefaults.make()
    nonisolated let suite: String
    init() { suite = defaults.string(forKey: "_suite") ?? "" }
    let notifier = FakeNotifier()
    let data = tempDir()
    lazy var model = AppModel(engine: fake, defaults: defaults, notifier: notifier, dataOverride: data)

    func newModel() -> AppModel { AppModel(engine: fake, defaults: defaults, notifier: notifier, dataOverride: data) }
    var ctx: URL { model.watched!.ctx }
    var runID: String { ctx.lastPathComponent }
    func record() -> RunRecord? { defaults.data(forKey: "lastRun").flatMap { try? JSONDecoder().decode(RunRecord.self, from: $0) } }
    func save(_ r: RunRecord) { defaults.set(try! JSONEncoder().encode(r), forKey: "lastRun") }
    /// A run folder with these events (no run started by the fake).
    func folder(_ name: String, _ lines: [String]) -> URL {
        let c = data.appending(path: "logs/runs/\(name)")
        try! FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        if !lines.isEmpty { append(c.appending(path: "events.ndjson"), lines.map { $0 + "\n" }.joined()) }
        return c
    }
    deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }
}

let install = RunRequest.install(year: 2025, bottle: "rvt2025-a", source: nil)
let endOK = #"{"event":"end","exit_code":0,"result":"ok","failed_action":"","failed_steps":[],"log_dir":""}"#

@MainActor @Suite(.serialized) struct AppModelTests {

    @Test func requestArguments() {
        #expect(install.arguments == ["install", "2025", "rvt2025-a", "--yes"])
        #expect(install.with(.reextract).arguments == ["install", "2025", "rvt2025-a", "--yes", "--reextract"])
        #expect(RunRequest.rebuild(year: 2025, bottle: "b", source: .reuseExtracted).arguments == ["rebuild", "2025", "b", "--yes", "--reuse-extracted"])
        #expect(RunRequest.check(year: 2025, bottle: "b", source: nil).with(.reuseExtracted).arguments == ["check", "2025", "b", "--reuse-extracted"])
        #expect(RunRequest.addins(year: 2025, bottle: "b", ids: ["pyrevit", "revitlookup"], eula: []).arguments == ["addins", "2025", "b", "--only", "pyrevit,revitlookup"])
        #expect(RunRequest.addins(year: 2027, bottle: "b", ids: ["enscape"], eula: ["enscape"]).arguments == ["addins", "2027", "b", "--only", "enscape", "--accept-eula", "enscape"])
        #expect(RunRequest.remove(year: 2025, bottle: "b").arguments == ["remove", "2025", "b", "--yes"])
        #expect(RunRequest.stop(year: 2025, bottle: "b").arguments == ["stop", "2025", "b"])
        #expect(RunRequest.remove(year: 2025, bottle: "b").with(.reextract) == .remove(year: 2025, bottle: "b"))
        #expect(install.cancellable && !RunRequest.remove(year: 2025, bottle: "b").cancellable && !RunRequest.stop(year: 2025, bottle: "b").cancellable)
    }

    @Test func startMakesANewRunFolderPassesTheExactArgsSavesTheRecord() async throws {
        let h = Harness()
        try await h.model.start(install)
        let first = h.ctx
        await h.fake.emit([endOK]); await h.model.poll()
        #expect(h.model.watched?.phase == .ended)
        try await h.model.start(install)
        let second = h.ctx
        #expect(first != second)
        for c in [first, second] {
            #expect(c.deletingLastPathComponent().path == h.data.appending(path: "logs/runs").path)
            #expect(c.lastPathComponent.hasPrefix("app-"))
        }
        #expect(await h.fake.started.last == ["install", "2025", "rvt2025-a", "--yes"])
        let r = try #require(h.record())
        #expect(r.ctx == second.path); #expect(r.runID == second.lastPathComponent); #expect(r.pid == 4242)
        #expect(r.pidStart == FakeEngine.startTime); #expect(r.request == install)
    }

    @Test func startRefusesWhileBusy() async throws {
        let h = Harness()
        await h.fake.setStatus([statusOut(busy: true, command: "install.sh 2025 rvt2025-a")])
        await h.model.refresh()
        await #expect(throws: (any Error).self) { try await h.model.start(install) }
        #expect(await h.fake.started.isEmpty)
    }

    @Test func dataOverrideWinsOverStatus() async throws {
        let h = Harness()
        await h.fake.setStatus([statusOut(appData: "/from/status")])
        await h.model.refresh()
        #expect(h.model.dataFolder?.path == h.data.path)
        let plain = AppModel(engine: h.fake, defaults: h.defaults, notifier: h.notifier)
        await plain.refresh()
        #expect(plain.dataFolder?.path == "/from/status")
    }

    @Test func twoStartsAtOnceTheSecondIsRefused() async throws {
        let h = Harness()
        await h.fake.closeGate()
        let model = h.model
        let first = Task { try await model.start(install) }
        for _ in 0..<100 where !(await h.fake.waitingAtGate) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await h.fake.waitingAtGate)
        await #expect(throws: (any Error).self) { try await model.start(install) }
        await h.fake.openGate()
        try await first.value
        #expect(await h.fake.started.count == 1)
        #expect(h.record() != nil)
    }

    @Test func pollFollowsTheEventsAndEndsOnce() async throws {
        let h = Harness()
        try await h.model.start(install)
        let lines = eventLines("install-ok.ndjson")
        await h.fake.emit(Array(lines[0..<6])); await h.model.poll()
        #expect(h.model.watched?.state.currentAction == "revit"); #expect(h.model.watched?.phase == .running); #expect(h.model.isBusy)
        let before = await h.fake.calls.count
        await h.fake.emit(Array(lines[6...])); await h.model.poll()
        #expect(h.model.watched?.phase == .ended); #expect(h.model.failure == nil); #expect(h.notifier.posts.count == 1)
        #expect(await h.fake.calls[before...].contains("status")); #expect(!h.model.isBusy)
        await h.model.poll()
        #expect(h.notifier.posts.count == 1)
    }

    @Test func partialEndsAsAFailureWithSteps() async throws {
        let h = Harness()
        try await h.model.start(install)
        await h.fake.emit(eventLines("install-partial.ndjson")); await h.model.poll()
        #expect(h.model.failure == .partial(steps: ["dynamo"], logDir: "/tmp/data/logs/rvt2025-a/20261017-111501-install", downloadFailed: false))
    }

    @Test func aDeadSupervisorAndAFreeLockIsInterruptedAndTheAppIsFreeAgain() async throws {
        let h = Harness()
        await h.fake.setStatus([statusOut()])
        try await h.model.start(install)
        await h.fake.emit(eventLines("no-end.ndjson"))
        try Data("log_dir=/l\n".utf8).write(to: h.ctx.appending(path: "result"))
        await h.fake.setStarts([:])
        await h.model.poll()
        #expect(h.model.watched?.phase == .interrupted); #expect(h.model.failure == .interrupted(logDir: "/l"))
        #expect(h.notifier.posts.count == 1); #expect(!h.model.isBusy)
        try await h.model.start(install)
        #expect(await h.fake.started.count == 2)
    }

    @Test func anEndWrittenBetweenTheTwoReadsIsNotAnInterruption() async throws {
        let h = Harness()
        await h.fake.setStatus([statusOut()])
        try await h.model.start(install)
        await h.fake.emit(eventLines("no-end.ndjson"))
        let fake = h.fake, ctx = h.ctx
        await h.fake.setStarts([:])
        await h.fake.setOnProcessStart { await fake.emit([endOK], ctx: ctx) }
        await h.model.poll()
        #expect(h.model.watched?.phase == .ended); #expect(h.model.failure == nil)
    }

    @Test func aDeadSupervisorWithAChildHoldingTheLockIsFinishing() async throws {
        let h = Harness()
        try await h.model.start(install)
        let busy = statusOut(busy: true, command: "install.sh 2025 rvt2025-a", runId: h.runID, pid: 4242, pidStart: FakeEngine.startTime, ctx: h.ctx.path)
        await h.fake.setStatus([busy, busy, statusOut()])
        await h.fake.emit(eventLines("no-end.ndjson")); await h.fake.setStarts([:])
        await h.model.poll()
        #expect(h.model.watched?.phase == .finishing); #expect(h.model.isBusy)
        if case .sent = await h.model.cancel() { Issue.record("cancel while finishing") }
        await h.model.poll()
        #expect(h.model.watched?.phase == .interrupted)
        #expect(await h.fake.interrupts.isEmpty)
    }

    @Test func aCachedFreeStatusIsNotTrustedWhenTheSupervisorDies() async throws {
        let h = Harness()
        await h.fake.setStatus([statusOut()])
        await h.model.refresh()
        try await h.model.start(install)
        await h.fake.setStatus([statusOut(busy: true, command: "install.sh 2025 rvt2025-a", runId: h.runID, pid: 4242, ctx: h.ctx.path)])
        await h.fake.setStarts([:])
        await h.model.poll()
        #expect(h.model.watched?.phase == .finishing)
    }

    @Test func aFailedRefreshAtThatMomentKeepsThePhase() async throws {
        let h = Harness()
        await h.fake.setStatus([statusOut()])
        await h.model.refresh()
        try await h.model.start(install)
        await h.fake.setStatus([failedStatus]); await h.fake.setStarts([:])
        await h.model.poll()
        #expect(h.model.watched?.phase == .running); #expect(h.notifier.posts.isEmpty)
    }

    @Test func aCheckRunWithoutTheLockIsWatchedThroughItsProcess() async throws {
        let h = Harness()
        await h.fake.setStatus([statusOut()])
        try await h.model.start(.check(year: 2025, bottle: "rvt2025-a", source: nil))
        await h.model.poll(); await h.model.poll()
        #expect(h.model.watched?.phase == .running)
        #expect(await h.model.cancel() == .sent)
        await h.fake.setStarts([:])
        await h.model.poll()
        #expect(h.model.watched?.phase == .interrupted)
    }

    @Test func aCheckIsCancellableWhileAnotherTaskHoldsTheLock() async throws {
        let h = Harness()
        await h.fake.setStatus([statusOut()])
        try await h.model.start(.check(year: 2025, bottle: "rvt2025-a", source: nil))
        await h.fake.setStatus([statusOut(busy: true, command: "install.sh 2026 rvt2026-a", runId: "other", pid: 777, ctx: "/elsewhere")])
        #expect(await h.model.cancel() == .sent)
    }

    @Test func launchReattachesToItsOwnRunAfterARestartAndKeepsTheRequest() async throws {
        let h = Harness()
        let req = RunRequest.addins(year: 2027, bottle: "rvt2027-a", ids: ["enscape"], eula: ["enscape"])
        try await h.model.start(req)
        let ctx = h.ctx
        await h.fake.setStatus([statusOut(busy: true, command: "./revit addins 2027 rvt2027-a", runId: ctx.lastPathComponent, pid: 4242, pidStart: FakeEngine.startTime, ctx: ctx.path)])
        let again = h.newModel()
        await again.launch()
        #expect(again.watched?.record != nil); #expect(again.watched?.ctx.path == ctx.path); #expect(again.retryRequest == req)
        await h.fake.emit([#"{"event":"end","exit_code":1,"result":"partial","failed_action":"","failed_steps":["enscape"],"log_dir":"/l","reason":"download"}"#], ctx: ctx)
        await again.poll()
        #expect(again.failure == .partial(steps: ["enscape"], logDir: "/l", downloadFailed: true))
    }

    @Test func aTerminalRunWithEventsIsNeverTheApps() async throws {
        let h = Harness()
        let mine = h.folder("app-old", eventLines("install-ok.ndjson"))
        h.save(RunRecord(ctx: mine.path, runID: "app-old", request: install, pid: 999, pidStart: "Thu Oct 15 09:00:00 2026"))
        let term = h.folder("20261017-101500-555", eventLines("no-end.ndjson"))
        await h.fake.setStatus([statusOut(busy: true, command: "install.sh 2025 rvt2025-a", runId: term.lastPathComponent, pid: 555, pidStart: "x", ctx: term.path)])
        await h.fake.setStarts([555: "x"])
        await h.model.launch()
        #expect(h.model.watched?.ctx.path == term.path); #expect(h.model.watched?.record == nil); #expect(h.model.retryRequest == nil)
        if case .sent = await h.model.cancel() { Issue.record("cancelled a run the app did not start") }
        #expect(await h.fake.interrupts.isEmpty)
    }

    @Test func aTerminalRunWithoutEventsIsBusyTextOnly() async throws {
        let h = Harness()
        await h.fake.setStatus([statusOut(busy: true, command: "install.sh 2025 rvt2025-a")])
        await h.model.launch()
        #expect(h.model.watched == nil); #expect(h.model.busyText == "install.sh 2025 rvt2025-a"); #expect(h.model.isBusy)
    }

    @Test func launchReportsTheAppsLastRunThatNeverEnded() async throws {
        let h = Harness()
        let c = h.folder("app-gone", eventLines("no-end.ndjson"))
        h.save(RunRecord(ctx: c.path, runID: "app-gone", request: install, pid: 999, pidStart: "Thu Oct 15 09:00:00 2026"))
        await h.fake.setStatus([statusOut()])
        await h.model.launch()
        #expect(h.model.watched?.phase == .interrupted); #expect(h.model.failure == .interrupted(logDir: ""))
        #expect(h.notifier.posts.count == 1)
    }

    @Test func launchLeavesAnEndedLastRunAlone() async throws {
        let h = Harness()
        let c = h.folder("app-done", eventLines("install-ok.ndjson"))
        h.save(RunRecord(ctx: c.path, runID: "app-done", request: install, pid: 999, pidStart: "x"))
        await h.fake.setStatus([statusOut()])
        await h.model.launch()
        #expect(h.model.watched == nil); #expect(h.notifier.posts.isEmpty)
    }

    @Test func cancelInterruptsWhenEverythingMatches() async throws {
        let h = Harness()
        try await h.model.start(install)
        await h.fake.setStatus([statusOut(busy: true, command: "install.sh 2025 rvt2025-a", runId: h.runID, pid: 4242, pidStart: FakeEngine.startTime, ctx: h.ctx.path)])
        #expect(await h.model.cancel() == .sent)
        #expect(await h.fake.interrupts == [Interrupt(pid: 4242, start: FakeEngine.startTime)])
        let calls = await h.fake.calls
        let s = try #require(calls.lastIndex(of: "status")), i = try #require(calls.lastIndex(of: "interrupt"))
        #expect(s < i)
    }

    enum Refusal: String, CaseIterable, Sendable {
        case refreshFails, noRecord, otherRunHoldsTheLock, sameRunOtherPid, alreadyEnded, finishing, removeRun
        case processGone, startDiffers, notALeader
    }

    @Test(arguments: Refusal.allCases) func cancelRefuses(_ c: Refusal) async throws {
        let h = Harness()
        let req: RunRequest = c == .removeRun ? .remove(year: 2025, bottle: "rvt2025-a") : install
        if c == .noRecord {
            let term = h.folder("20261017-101500-555", eventLines("no-end.ndjson"))
            await h.fake.setStatus([statusOut(busy: true, command: "install.sh", runId: term.lastPathComponent, pid: 555, pidStart: "x", ctx: term.path)])
            await h.fake.setStarts([555: "x"]); await h.fake.setLeaders([555])
            await h.model.launch()
        } else {
            try await h.model.start(req)
        }
        let mineBusy = statusOut(busy: true, command: "install.sh 2025 rvt2025-a", runId: h.model.watched!.ctx.lastPathComponent, pid: 4242, pidStart: FakeEngine.startTime, ctx: h.model.watched!.ctx.path)
        var expectInterruptCall = false
        switch c {
        case .refreshFails: await h.fake.setStatus([failedStatus])
        case .noRecord: break
        case .otherRunHoldsTheLock: await h.fake.setStatus([statusOut(busy: true, command: "x", runId: "other", pid: 4242)])
        case .sameRunOtherPid: await h.fake.setStatus([statusOut(busy: true, command: "x", runId: h.runID, pid: 999)])
        case .alreadyEnded: await h.fake.emit([endOK]); await h.model.poll(); await h.fake.setStatus([statusOut()])
        case .finishing:
            await h.fake.setStatus([mineBusy]); await h.fake.setStarts([:]); await h.model.poll()
            #expect(h.model.watched?.phase == .finishing)
        case .removeRun: await h.fake.setStatus([mineBusy])
        case .processGone: await h.fake.setStatus([mineBusy]); await h.fake.setStarts([:]); expectInterruptCall = true
        case .startDiffers: await h.fake.setStatus([mineBusy]); await h.fake.setStarts([4242: "Fri Oct 16 08:00:00 2026"]); expectInterruptCall = true
        case .notALeader: await h.fake.setStatus([mineBusy]); await h.fake.setLeaders([]); expectInterruptCall = true
        }
        let out = await h.model.cancel()
        if case .sent = out { Issue.record("sent for \(c)") }
        if expectInterruptCall { #expect(out == .refused("The task has already ended.")) }
        let calls = await h.fake.interrupts.count
        #expect(calls == (expectInterruptCall ? 1 : 0))
    }
}
