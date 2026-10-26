// The trackpad helper's coordinator (spec 2026-10-26-trackpad §1–4, §7): everything the helper does except the event
// tap's callback. It asks for the permission once and checks it every 2 s; keeps a tap only while it is allowed and a
// Revit runs, and makes sure our own events get through (a probe: macOS's own check says "no" until the helper
// restarts, step 0); follows the Revits and their bottles (revit status --json) with one hittest client per bottle;
// hands cancels to the gesture machine before it stops anything; checks hittest's screens again when they change;
// writes <data>/trackpad/state.json when something changes. Asking the app to start it again ("restart") and leaving
// both end in `exited`.
import CoreGraphics
import Foundation
import TrackpadCore
import TrackpadState

/// The screens' union as the hittest clients compare their hello with it (read on their threads).
final class UnionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rect: CGRect
    init(_ r: CGRect) { rect = r }
    var value: CGRect { get { lock.withLock { rect } } set { lock.withLock { rect = newValue } } }
}

@MainActor public final class HelperCoordinator {
    let args: HelperArgs, ports: HelperPorts
    private let union: UnionBox
    private var state: HelperState
    private var lastWritten: HelperState?
    private var tapOn = false, prompted = false
    private var revits: [Int32: String] = [:]                          // Revit pid → its bottle
    private var bottles: [String: (year: Int, client: any HelperClient)] = [:]
    private var disables: [Double] = []
    private var arriving: Set<Int32> = []                              // Revits being looked up (status retries)
    public private(set) var exited = false
    public var onExit: (() -> Void)?

    public init(args: HelperArgs, ports: HelperPorts, pid: Int32, start: String) {
        self.args = args; self.ports = ports
        union = UnionBox(ports.display.union())
        state = HelperState(session: args.session, pid: pid, start: start, trusted: false, posting: false, tap: false,
                            error: nil, restart: nil, bottles: [:])
    }

    private var log: TrackpadLog { ports.log }

    public func start() async {
        if args.recoverOnly {   // the last helper ended unexpectedly and the switch is off: only let the button go
            if ports.permission.trusted() { ports.tap.post([.up(ports.tap.cursor(), [])]) }
            log.line("recover only"); finish(); return
        }
        if args.recover && ports.permission.trusted() {
            ports.tap.post([.up(ports.tap.cursor(), [])])
            log.line("recover: middle button released")
        }
        log.line("started")
        if !prompted { prompted = true; ports.permission.prompt() }
        for pid in ports.workspace.runningRevitPids().sorted() where !exited { await revitLaunched(pid) }
        await checkPermission()
    }

    /// Every 2 s (and after each change): the permission, the tap, the bottles' state.
    public func checkPermission() async {
        guard !exited else { return }
        let trusted = ports.permission.trusted()
        state.trusted = trusted
        if trusted && !tapOn && !revits.isEmpty && state.error == nil {
            guard ports.tap.create() else { return restart("the event tap could not be created") }
            guard await ports.tap.probePosting() else {
                ports.tap.disable()
                return restart("our own test event did not come back")
            }
            tapOn = true; state.posting = true
            log.line("tap on")
        } else if !trusted && tapOn {
            await ports.tap.cancelAndDisable(.permissionLost)
            tapOn = false; state.posting = false
            log.line("permission lost: tap off")
        } else if tapOn && revits.isEmpty {
            await ports.tap.cancelAndDisable(.switchOff)
            tapOn = false
            log.line("no Revit: tap off")
        }
        state.tap = tapOn
        await refreshBottles()
    }

    /// The bottles' line in the state from their clients.
    public func refreshBottles() async {
        var b: [String: BottleState] = [:]
        for (name, v) in bottles {
            switch v.client.status {
            case .ready: b[name] = BottleState(ready: true, error: nil)
            case .notReady(let w), .failed(let w): b[name] = BottleState(ready: false, error: w)
            default: b[name] = BottleState(ready: false, error: nil)
            }
        }
        state.bottles = b
        save()
    }

    /// Every 2 s: Revits that started or ended without a notification.
    public func syncRevits() async {
        let now = ports.workspace.runningRevitPids()
        for pid in revits.keys.sorted() where !now.contains(pid) { await revitTerminated(pid) }
        for pid in now.sorted() where revits[pid] == nil { await revitLaunched(pid) }
    }

    public func revitLaunched(_ pid: Int32) async {
        guard revits[pid] == nil, !arriving.contains(pid), !exited else { return }
        arriving.insert(pid)
        defer { arriving.remove(pid) }
        var found: EngineBottle?
        for (i, wait) in ([0.0] + TrackpadConstants.statusRetries).enumerated() {
            if i > 0 { await ports.clock.sleep(wait) }
            found = await ports.engine.status().first { $0.pids.contains(pid) }
            if found != nil || exited { break }
        }
        guard let b = found, !exited else { log.line("Revit \(pid): in no bottle, left alone"); return }
        revits[pid] = b.bottle
        if bottles[b.bottle] == nil {
            let u = union
            let c = ports.clients.make(year: b.year, bottle: b.bottle) { DisplayMap.scale(hello: $0, cgUnion: u.value) }
            let name = b.bottle
            c.onChange { [weak self] s in Task { @MainActor in await self?.clientChanged(bottle: name, s) } }
            bottles[b.bottle] = (b.year, c)
            c.start()
        }
        log.line("Revit \(pid) in \(b.bottle) (\(b.year))")
        pushContext()
        await checkPermission()
    }

    public func revitTerminated(_ pid: Int32) async {
        guard let bottle = revits[pid] else { return }
        await ports.tap.cancel(.targetGone(pid))        // the button up first, then the rest
        revits[pid] = nil
        if !revits.values.contains(bottle), let v = bottles.removeValue(forKey: bottle) { v.client.stop() }
        log.line("Revit \(pid) ended")
        pushContext()
        await checkPermission()
    }

    /// A bottle's hittest is no longer ready (or is again): a gesture over that bottle's Revit ends at once.
    public func clientChanged(bottle: String, _ s: ClientStatus) async {
        guard bottles[bottle] != nil else { return }
        if case .ready = s {} else {
            for (pid, b) in revits.sorted(by: { $0.key < $1.key }) where b == bottle { await ports.tap.cancel(.hittestFailed(pid)) }
        }
        await refreshBottles()
    }

    public func activated(_ pid: Int32) async {
        await ports.tap.cancel(.activated(pid))
    }

    /// The first sign of a display change, at once: the gesture ends and every hittest starts again, so no decision is
    /// made with the old screens until a fresh hello fits (displaysChanged follows when the changes have settled).
    public func blockForDisplays() async {
        await ports.tap.cancel(.displays)
        for v in bottles.values { v.client.restart() }
    }

    /// The screens changed: no gesture goes on, every hittest starts again and must agree with the new screens; while
    /// one does not ("unknown display layout"), it is asked again every second, ten times.
    public func displaysChanged() async {
        await ports.tap.cancel(.displays)
        union.value = ports.display.union()
        for v in bottles.values { v.client.restart() }
        for _ in 0..<TrackpadConstants.displayRetries {
            await ports.clock.sleep(TrackpadConstants.displayRetry)
            let waiting = bottles.values.filter { $0.client.status == .notReady("unknown display layout") }
            if waiting.isEmpty { break }
            union.value = ports.display.union()
            for v in waiting { v.client.restart() }
        }
        await refreshBottles()
    }

    /// macOS turned the tap off (a slow callback, or secure input); the tap's thread has turned it on again. Too often:
    /// an error, and the tap stays off.
    public func tapDisabledByMacOS() async {
        let now = ports.clock.now()
        disables = disables.filter { now - $0 < TrackpadConstants.tapDisableWindow } + [now]
        log.line("tap disabled by macOS")
        guard disables.count > TrackpadConstants.tapDisablesToError, tapOn else { return }
        await ports.tap.cancelAndDisable(.tapDisabled); tapOn = false; state.tap = false
        state.error = "macOS turned the event tap off too often"
        log.line("tap off: \(state.error!)")
        save()
    }

    public func shutdown(reason: String) async {
        guard !exited else { return }
        await ports.tap.cancelAndDisable(.switchOff)
        tapOn = false
        state.tap = false
        for v in bottles.values { v.client.shutdown() }
        bottles = [:]; revits = [:]
        log.line("exit: \(reason)")
        finish()
    }

    private func restart(_ why: String) {
        state.restart = why; state.tap = false
        log.line("restart: \(why)")
        finish()
    }

    private func finish() {
        save()
        log.flush()
        exited = true
        onExit?()
    }

    private func pushContext() {
        var r: [Int32: RevitTarget] = [:]
        for (pid, bottle) in revits { if let v = bottles[bottle] { r[pid] = RevitTarget(bottle: bottle, year: v.year, client: v.client) } }
        ports.tap.setContext(DecideContext(revits: r))
    }

    private func save() {
        guard !args.recoverOnly, state != lastWritten else { return }
        ports.state.write(state)
        lastWritten = state
    }
}
