// Activity: the app's runs, from their folders under <data>/logs/runs. Each holds the events the engine wrote, so a
// past run reads as it went. Runs of the command line without --events have no such file and do not show.
import Foundation

public struct RunRow: Identifiable, Equatable, Sendable {
    public enum Outcome: Equatable, Sendable { case running, done, partial, failed, stopped, interrupted }
    public var id: String { ctx.path }
    public let ctx: URL
    public let title, bottle: String
    public let date: Date
    public let outcome: Outcome
    public let state: RunState
}

public enum ActivityLog {
    /// The newest runs first. active: the folder of the run that goes on now.
    public static func load(runs: URL, active: URL?, limit: Int = 50) -> [RunRow] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil)) ?? []
        let dated = dirs.compactMap { d -> (URL, Date)? in
            let f = d.appending(path: "events.ndjson")
            return ((try? fm.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date).map { (d, $0) }
        }.sorted { $0.1 > $1.1 }
        var rows: [RunRow] = []
        for (d, date) in dated where rows.count < limit {
            var r = NDJSONReader(url: d.appending(path: "events.ndjson"))
            let events = (try? r.readNew()) ?? []
            guard !events.isEmpty else { continue }
            let s = RunState.replay(events)
            let y = s.year.map(String.init) ?? ""
            rows.append(RunRow(ctx: d, title: MenuContent.verb(s.command ?? "", y), bottle: s.bottle ?? "", date: date,
                               outcome: outcome(s, active: d.lastPathComponent == active?.lastPathComponent), state: s))
        }
        return rows
    }

    static func outcome(_ s: RunState, active: Bool) -> RunRow.Outcome {
        if active && s.end == nil { return .running }
        switch s.end?.kind {
        case .ok?: return .done
        case .partial?: return .partial
        case .stopped?: return .stopped
        case nil: return .interrupted
        default: return .failed
        }
    }
}
