// Revit 2027 follows the Mac's look while it runs (spec 2026-10-27-dark-theme §5): when the Mac turns light or dark, or
// a Revit starts in a bottle that follows the Mac (theme_mode "mac" in status), the engine's `theme <year> <bottle>`
// sets the bottle's Windows theme and tells Revit. The app only decides when; the engine reads the Mac's look itself.
// One call at a time for the whole app, never awaited by the poll loop. A call that fails (busy lock, Revit did not
// answer) is tried again on the next kick, bottles in turn, until it works or the bottle is no longer a target.
import Foundation
import os

@MainActor public final class ThemeSync {
    /// What a bottle should have: the Mac's look as of `generation`, for this set of Revit processes.
    struct Want: Equatable { let generation: Int; let pids: Set<Int32> }
    struct Target { var want: Want; var done: Want?; let year: String }

    private let engine: any EngineClient
    private let log = Logger(subsystem: "revit-macos", category: "theme")
    private(set) var generation = 0
    private(set) var targets: [String: Target] = [:]           // bottle → what it should have and what it got
    private(set) var active: (bottle: String, attempt: Int, want: Want)?
    private var attempts = 0
    private var cursor = ""                                     // the bottle tried last: the next kick starts after it

    public init(engine: any EngineClient) { self.engine = engine }

    /// From status: the bottles where Revit 2027 runs and the theme follows the Mac. A new Revit process changes what
    /// the bottle should have; a bottle that is no longer one is dropped (a call on its way is not).
    public func update(bottles: [Bottle]) {
        var seen = Set<String>()
        for b in bottles where b.yearNumber == 2027 && !b.revitPids.isEmpty && b.themeMode == "mac" {
            seen.insert(b.name)
            let w = Want(generation: generation, pids: Set(b.revitPids))
            if var t = targets[b.name] {
                if t.want.pids != w.pids { t.want = w; targets[b.name] = t }
            } else {
                targets[b.name] = Target(want: w, done: nil, year: b.year)
            }
        }
        for name in targets.keys where !seen.contains(name) { targets[name] = nil }
    }

    /// The Mac turned light or dark: every target should have the new look.
    public func appearanceChanged() {
        generation += 1
        for (name, t) in targets { targets[name]?.want = Want(generation: generation, pids: t.want.pids) }
    }

    /// Starts the next call, if none is on its way: the first target after the last one tried that has not got what
    /// it should have. Returns at once.
    public func kick() {
        guard active == nil else { return }
        let names = targets.keys.sorted()
        guard !names.isEmpty else { return }
        let start = (names.firstIndex { $0 > cursor }) ?? 0
        for i in 0..<names.count {
            let name = names[(start + i) % names.count]
            guard let t = targets[name], t.done != t.want else { continue }
            attempts += 1
            let attempt = attempts, want = t.want
            active = (name, attempt, want); cursor = name
            let engine = engine
            Task { [weak self] in
                let rc: Int32
                do { rc = try await engine.run(["theme", t.year, name]).exitCode } catch { rc = -1 }
                self?.finished(name: name, attempt: attempt, want: want, rc: rc)
            }
            return
        }
    }

    func finished(name: String, attempt: Int, want: Want, rc: Int32) {
        guard active?.attempt == attempt else { return }
        active = nil
        if rc == 0, targets[name]?.want == want { targets[name]?.done = want }
        if rc != 0 { log.info("theme \(name, privacy: .public): exit \(rc), tried again later") }
    }
}
