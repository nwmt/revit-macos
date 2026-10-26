// The decision at the start of a gesture (spec §6), on the event tap's thread: no mouse button down, the Mac window
// under the point is a known Revit's, its bottle's hittest is ready and answers in time, and the window there is a
// view (ViewRule). The log gets the class of the window and the decision: never its title, never the point.
import CoreGraphics
import Foundation
import TrackpadCore

public struct RevitTarget: Sendable {
    public let bottle: String, year: Int
    public let client: any HitQuerying
    public init(bottle: String, year: Int, client: any HitQuerying) { self.bottle = bottle; self.year = year; self.client = client }
}

/// What the tap's thread knows of the running Revits: replaced as a whole when it changes.
public struct DecideContext: Sendable {
    public var revits: [Int32: RevitTarget]
    public init(revits: [Int32: RevitTarget]) { self.revits = revits }
}

public enum Decider {
    public static func decide(at p: CGPoint, windows: [WinInfo], buttonsDown: Bool, context: DecideContext,
                              log: TrackpadLog? = nil) -> Target? {
        guard !buttonsDown else { return nil }
        guard let pid = WindowPick.target(at: p, frontToBack: windows, revitPids: Set(context.revits.keys)),
              let r = context.revits[pid] else { return nil }
        guard case .ready(let s) = r.client.status else { log?.line("pass: \(r.bottle) not ready"); return nil }
        guard let reply = r.client.query(DisplayMap.toWine(p, scale: s)) else { log?.line("pass: \(r.bottle) no answer"); return nil }
        let view = ViewRule.isView(year: r.year, reply: reply)
        log?.line("\(view ? "view" : "pass") \(reply.chain.first?.cls ?? "(no window)")")
        return view ? Target(pid: pid) : nil
    }
}
