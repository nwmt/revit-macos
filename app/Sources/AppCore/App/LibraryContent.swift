// The Library: one card per Revit bottle, and the restore points of bottles that are gone. Pure: views draw it.
import Foundation

public struct VersionCard: Equatable, Sendable {
    public let year: Int
    public let bottle: String
    public let status: String               // works, mostly, untested
    public let tested: String
    public let note: String                 // the year's gaps, or what runs in this bottle
    public let running, starting, hasPoint, taskHere: Bool
    public let pids: [Int32]
    public var ref: BottleRef { BottleRef(year: year, bottle: bottle) }
}

public struct OrphanPoints: Equatable, Sendable {
    public let bottle: String
    public let year: Int
    public let points: [RestorePoint]
}

public struct LibraryContent: Equatable, Sendable {
    public let cards: [VersionCard]
    public let orphans: [OrphanPoints]

    public static func make(status: EngineStatus?, watched: WatchedRun?, starting: Set<String>) -> LibraryContent {
        let bottles = status?.bottles ?? [], points = status?.restorePoints ?? []
        let active = watched.map { $0.phase == .running || $0.phase == .finishing } ?? false
        let cards = bottles.compactMap { b -> VersionCard? in
            guard let y = b.yearNumber else { return nil }
            let here = active && (watched?.state.bottle ?? watched?.record?.request.bottle) == b.name
            let note = here ? watched.flatMap { MenuContent.activity(status: status, watched: $0, failure: nil)?.title } : nil
            return VersionCard(year: y, bottle: b.name, status: b.support?.status ?? "untested", tested: b.support?.tested ?? "",
                               note: note ?? b.support?.gaps ?? "", running: b.running, starting: starting.contains(b.name),
                               hasPoint: points.contains { $0.bottle == b.name }, taskHere: here, pids: b.revitPids)
        }
        let known = Set(bottles.map(\.name))
        var order: [String] = []
        for p in points where !known.contains(p.bottle) && !order.contains(p.bottle) { order.append(p.bottle) }
        let orphans = order.compactMap { n -> OrphanPoints? in
            let ps = points.filter { $0.bottle == n }
            return ps.first.flatMap { Int($0.year) }.map { OrphanPoints(bottle: n, year: $0, points: ps) }
        }
        return LibraryContent(cards: cards, orphans: orphans)
    }
}
