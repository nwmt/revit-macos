// Settings › Storage: the restore points of every bottle, removed ones too, one row per bottle and year (./revit points
// works within a year). The plan and the deleting are the engine's (points --clear … --dry-run --json, then the run).
import Foundation

public struct PointRow: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case keepNewest, deleteAll }
    public let bottle: String
    public let year: Int
    public let count: Int
    public let bytes: Int64                    // up to: a point holds its size only once the bottle changes
    public let removed: Bool                   // no bottle of this name and year
    public let unfinished: Bool                // files of a run that was cut short
    public let action: Action?
    public var clear: String? { action.map { $0 == .keepNewest ? "old" : "all" } }
}

public struct StorageContent: Equatable, Sendable {
    public let points: [PointRow]
    public let leftoversOnly: [String]         // bottle names with files of a run cut short and no point: Finder only

    public static func make(_ s: EngineStatus?) -> StorageContent {
        guard let s else { return StorageContent(points: [], leftoversOnly: []) }
        let present = Set(s.bottles.map { "\($0.name)|\($0.year)" })
        let left = Set(s.restoreLeftovers)
        var rows: [PointRow] = []
        var seen: [String: [RestorePoint]] = [:], order: [String] = []
        for p in s.restorePoints {
            let k = "\(p.bottle)|\(p.year)"
            if seen[k] == nil { order.append(k) }
            seen[k, default: []].append(p)
        }
        for k in order {
            let ps = seen[k]!, first = ps[0]
            guard let y = Int(first.year) else { continue }
            let removed = !present.contains(k)
            let action: PointRow.Action? = removed ? .deleteAll : (ps.count > 1 ? .keepNewest : nil)
            rows.append(PointRow(bottle: first.bottle, year: y, count: ps.count, bytes: ps.reduce(0) { $0 + $1.bytes },
                                 removed: removed, unfinished: left.contains(first.bottle), action: action))
        }
        let named = Set(s.restorePoints.map(\.bottle))
        return StorageContent(points: rows, leftoversOnly: s.restoreLeftovers.filter { !named.contains($0) })
    }
}
