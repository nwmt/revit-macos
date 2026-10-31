// Prepare a folder: ./revit gdrive warm for one named folder, because a person asked. Mac files only, no lock, Revit may
// be open, so it is no task of the engine: it holds no place in Activity and writes nothing. It lives in memory, here.
import Foundation

@MainActor @Observable public final class WarmModel {
    public private(set) var bottle: String?             // what it prepares for now
    public private(set) var line = ""                   // the last line of the listing, or how it ended
    public private(set) var failed = false
    @ObservationIgnored private let engine: any EngineClient
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var run = 0             // a line that comes after its run ended is dropped

    public init(engine: any EngineClient) { self.engine = engine }

    public var running: Bool { bottle != nil }

    public func start(year: Int, bottle b: String, folder: String, depth: Int) {
        guard !running else { return }
        bottle = b; line = ""; failed = false
        run += 1
        let engine = engine, id = run
        let say: @Sendable (String) -> Void = { [weak self] l in
            Task { @MainActor in if let self, self.run == id, self.running { self.line = l } }
        }
        task = Task { [weak self] in
            let out = try? await engine.stream(["gdrive", "warm", String(year), b, folder, "--depth", String(depth)], onLine: say)
            self?.ended(out)
        }
    }

    private func ended(_ out: EngineOutput?) {
        let cancelled = task?.isCancelled ?? false
        bottle = nil; task = nil
        guard !cancelled else { line = String(localized: "Stopped."); return }
        guard let out else { failed = true; line = String(localized: "Could not start the listing."); return }
        if out.exitCode != 0 {
            failed = true
            let e = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)   // what it says when it fails midway is on stdout
            line = e.isEmpty ? String(decoding: out.stdout, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? line : e
        } else if let l = String(decoding: out.stdout, as: UTF8.self).split(separator: "\n").last(where: { $0.contains("folders listed") }) {
            line = String(l)   // not the note on deeper folders after it
        }
    }

    public func cancel() { task?.cancel() }
}
