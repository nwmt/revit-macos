// Fakes of the helper's ports: they record what the coordinator does, in order, in one journal.
import CoreGraphics
import Foundation
@testable import TrackpadCore
@testable import TrackpadIO
import TrackpadState

@MainActor final class Journal { var lines: [String] = [] }

@MainActor final class FakeWorkspace: WorkspacePort {
    var pids: Set<Int32> = []
    func runningRevitPids() -> Set<Int32> { pids }
}

@MainActor final class FakePermission: PermissionPort {
    var isTrusted = true, prompts = 0
    func trusted() -> Bool { isTrusted }
    func prompt() { prompts += 1 }
}

@MainActor final class FakeTap: TapPort {
    let j: Journal
    var createOK = true, probeOK = true, cancelDelay: UInt64 = 0
    var contexts: [DecideContext] = []
    var on = false
    var where_ = CGPoint(x: 5, y: 6)
    init(_ j: Journal) { self.j = j }
    func create() -> Bool { j.lines.append("create"); on = createOK; return createOK }
    func probePosting() async -> Bool { j.lines.append("probe"); return probeOK }
    func disable() { j.lines.append("disable"); on = false }
    func post(_ p: [Post]) { for x in p { j.lines.append("post \(x)") } }
    func setContext(_ c: DecideContext) { contexts.append(c) }
    func cancel(_ r: CancelReason) async {
        j.lines.append("cancel \(r)")
        if cancelDelay > 0 { try? await Task.sleep(nanoseconds: cancelDelay) }
        j.lines.append("cancelled \(r)")   // the machine's up has been posted by now
    }
    func cancelAndDisable(_ r: CancelReason) async { j.lines.append("cancelAndDisable \(r)"); on = false }
    func cursor() -> CGPoint { where_ }
}

final class FakeEngine: EnginePort, @unchecked Sendable {
    var answers: [[EngineBottle]] = []     // one per call; the last one repeats
    var calls = 0
    func status() async -> [EngineBottle] {
        calls += 1
        return answers.isEmpty ? [] : answers[min(calls - 1, answers.count - 1)]
    }
}

@MainActor final class FakeDisplay: DisplayPort {
    var rect = CGRect(x: 0, y: 0, width: 1512, height: 982)
    func union() -> CGRect { rect }
}

final class FakeClient: HelperClient, @unchecked Sendable {
    let bottle: String
    let journal: Journal
    var status: ClientStatus = .ready(scale: 2)
    var reply: HitReply?
    var asked: [WinePoint] = []
    var restarts = 0
    var watcher: (@Sendable (ClientStatus) -> Void)?
    init(_ bottle: String, _ j: Journal) { self.bottle = bottle; self.journal = j }
    func onChange(_ f: @escaping @Sendable (ClientStatus) -> Void) { watcher = f }
    func query(_ p: WinePoint) -> HitReply? { asked.append(p); return reply }
    func start() { MainActor.assumeIsolated { journal.lines.append("start \(bottle)") } }
    func stop() { MainActor.assumeIsolated { journal.lines.append("stop \(bottle)") } }
    func shutdown() { MainActor.assumeIsolated { journal.lines.append("shutdown \(bottle)") } }
    func restart() { restarts += 1 }
}

@MainActor final class FakeClients: ClientFactory {
    let j: Journal
    var made: [String: FakeClient] = [:]
    var onMake: ((FakeClient) -> Void)?
    init(_ j: Journal) { self.j = j }
    func make(year: Int, bottle: String, scale: @escaping @Sendable (CGRect) -> Int?) -> any HelperClient {
        let c = FakeClient(bottle, j); made[bottle] = c; onMake?(c); return c
    }
}

@MainActor final class FakeState: StatePort {
    var states: [HelperState] = []
    func write(_ s: HelperState) { states.append(s) }
}

final class FakeClock: ClockPort, @unchecked Sendable {
    var t = 1000.0, slept: [Double] = []
    func now() -> Double { t }
    func sleep(_ s: Double) async { slept.append(s); t += s }
}

@MainActor struct World {
    let j = Journal()
    let ws = FakeWorkspace(), perm = FakePermission(), engine = FakeEngine(), display = FakeDisplay()
    let state = FakeState(), clock = FakeClock()
    let tap: FakeTap, clients: FakeClients, log: TrackpadLog, dir: URL
    init() {
        tap = FakeTap(j); clients = FakeClients(j); dir = tempDir(); log = TrackpadLog(url: dir.appending(path: "logs/trackpad.log"))
    }
    func coordinator(recover: Bool = false, recoverOnly: Bool = false) -> HelperCoordinator {
        let a = HelperArgs(session: "s1", parentPid: 1, parentStart: "x", engine: URL(fileURLWithPath: "/e"), data: dir,
                           recover: recover, recoverOnly: recoverOnly)
        return HelperCoordinator(args: a, ports: HelperPorts(workspace: ws, permission: perm, tap: tap, engine: engine,
                                 display: display, clients: clients, state: state, clock: clock, log: log),
                                 pid: 4242, start: "now")
    }
    func revit(_ pid: Int32, _ bottle: String = "rvt2027-a", _ year: Int = 2027) {
        ws.pids.insert(pid); engine.answers = [[EngineBottle(bottle: bottle, year: year, pids: [pid])]]
    }
}
