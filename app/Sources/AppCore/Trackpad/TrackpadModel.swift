// "Trackpad in Revit" (spec 2026-10-26-trackpad §1–2): the switch (off by default), the helper that does the work, and
// the line Settings shows. The helper runs only while the switch is on and this app runs; a new helper starts only after
// the old one has ended (its arguments reach a new instance only). Every operation has a generation: what an await brings
// back after the switch moved is undone. An exit we did not ask for is a crash: the next helper first lets the middle
// button go (--recover), or only does that when the switch is off now (--recover-only); three in a row are an error.
import Foundation
import Observation
import TrackpadState

public enum TrackpadLine: Equatable, Sendable {
    case off, starting, on, waiting(section: String), lost, lostManual, error(String), notInApplications
}

@MainActor @Observable public final class TrackpadModel {
    public private(set) var line: TrackpadLine = .off
    public private(set) var enabled: Bool

    @ObservationIgnored let launcher: any HelperLauncher
    @ObservationIgnored let resetter: any PermissionResetter
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let engine: URL
    @ObservationIgnored let helperID: String
    @ObservationIgnored let data: () -> URL?
    @ObservationIgnored let placement: () -> String?
    @ObservationIgnored let parent: () async -> (Int32, String)?
    @ObservationIgnored let sleep: @MainActor (Double) async -> Void
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var current: HelperInstance?
    @ObservationIgnored private var session = ""
    @ObservationIgnored private var expected: Set<HelperInstance> = []
    @ObservationIgnored private var crashes = 0
    @ObservationIgnored private var needsRecover = false       // a helper crashed: the next one lets the button go first
    public static let section = "Device Control and Data Access"   // System Settings → Privacy & Security, macOS 27

    public init(launcher: any HelperLauncher, resetter: any PermissionResetter, defaults: UserDefaults, engine: URL,
                data: @escaping () -> URL?, placement: @escaping () -> String?, parent: @escaping () async -> (Int32, String)?,
                helperID: String, sleep: @escaping @MainActor (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.launcher = launcher; self.resetter = resetter; self.defaults = defaults; self.engine = engine; self.data = data
        self.placement = placement; self.parent = parent; self.helperID = helperID; self.sleep = sleep
        enabled = defaults.bool(forKey: "trackpadEnabled")
    }

    private var placed: Bool { placement() == "ok" }

    public func start() async {
        guard enabled else { line = placed ? .off : .notInApplications; return }
        await launchFresh(recover: false, recoverOnly: false)
    }

    public func setEnabled(_ on: Bool) async {
        generation += 1
        guard !on || placed else { line = .notInApplications; return }
        enabled = on; defaults.set(on, forKey: "trackpadEnabled")
        crashes = 0
        if on { await launchFresh(recover: false, recoverOnly: false) } else { await stopHelper(); line = .off }
    }

    /// The helper ended. Ours to ask for (expected) or not (a crash).
    public func helperExited(_ h: HelperInstance) async {
        if expected.remove(h) != nil { if current == h { current = nil }; return }
        guard current == h else { return }
        current = nil
        crashes += 1; needsRecover = true
        if enabled && crashes >= 3 { line = .error(String(localized: "The helper stopped \(crashes) times")); return }
        let g = generation
        await sleep(10)   // at most one start every 10 s
        if !enabled {     // off now: only the button, if no helper has let it go meanwhile
            if needsRecover { await launchFresh(recover: false, recoverOnly: true) }
            return
        }
        guard g == generation else { return }   // the switch moved meanwhile: that start recovered already
        await launchFresh(recover: true, recoverOnly: false)
    }

    /// The permission no longer fits the helper (it changed): stop it, reset its entry, ask again.
    public func askAgain() async {
        generation += 1
        let g = generation
        await stopHelper()
        guard g == generation else { return }
        guard await resetter.reset(bundleID: helperID), g == generation else {
            if g == generation { line = .lostManual }
            return
        }
        defaults.set(false, forKey: "trackpadWasTrusted")
        await launchFresh(recover: false, recoverOnly: false)
    }

    /// The helper's state.json, when it is this session's and this helper's.
    public func refresh() {
        guard enabled else { line = placed ? .off : .notInApplications; return }
        guard let h = current, let f = data()?.appending(path: "trackpad/state.json"), let s = StateFile.read(f),
              s.session == session, s.pid == h.pid else {
            if case .error = line {} else if line != .lostManual { line = .starting }
            return
        }
        if s.trusted { defaults.set(true, forKey: "trackpadWasTrusted") }
        if s.tap { crashes = 0 }
        if let e = s.error { line = .error(e) }
        else if s.trusted { line = .on }
        else { line = defaults.bool(forKey: "trackpadWasTrusted") ? .lost : .waiting(section: Self.section) }
    }

    /// Tests: the switch moves without the helper being told (between a crash and its restart).
    func enabledForTest(_ on: Bool) { enabled = on }

    private func launchFresh(recover: Bool, recoverOnly: Bool) async {
        let g = generation
        guard await replaceOld(), g == generation else { return }
        guard let d = data(), let (pid, start) = await parent(), g == generation else { return }
        session = UUID().uuidString
        let args = HelperArgs(session: session, parentPid: pid, parentStart: start, engine: engine, data: d,
                              recover: recover || (needsRecover && !recoverOnly), recoverOnly: recoverOnly)
        guard let h = try? await launcher.launch(args) else {
            if g == generation && (enabled || recoverOnly) { line = .error(String(localized: "The helper could not start")) }
            return
        }
        if args.recover || recoverOnly { needsRecover = false }
        if g != generation || (!enabled && !recoverOnly) {   // the switch moved meanwhile: undo
            expected.insert(h); launcher.terminate(h); return
        }
        if recoverOnly { expected.insert(h); return }     // it ends by itself
        current = h
        line = .starting
    }

    /// Every helper that runs is asked to quit; true once none is left.
    private func replaceOld() async -> Bool {
        for h in launcher.running() {
            expected.insert(h)
            launcher.terminate(h)
            if await gone(h) { continue }
            launcher.forceTerminate(h)
            if await !gone(h) { line = .error(String(localized: "The old helper does not quit")); return false }
        }
        return true
    }

    private func gone(_ h: HelperInstance) async -> Bool {
        for _ in 0..<30 { if !launcher.running().contains(h) { return true }; await sleep(0.1) }
        return !launcher.running().contains(h)
    }

    private func stopHelper() async {
        guard let h = current else { return }
        current = nil
        expected.insert(h)
        launcher.terminate(h)
        if await !gone(h) { launcher.forceTerminate(h) }
    }
}
