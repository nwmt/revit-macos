// The decision at the start of a gesture (spec §6), on the event tap's thread: no mouse button down, the Mac window
// under the point is a known Revit's, its bottle's hittest is ready and answers in time, and the window there is a
// view (ViewRule). The log gets the class of the window and the decision: never its title, never the point. A pass
// before hittest is asked gets a line too, once until the reason changes: a gesture that does nothing must say why.
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
    /// A mouse button the user holds. The middle button is ours while a pan runs (the helper's own down, whose up is
    /// sent only after the next gesture is decided): then it does not count (final review: pan → pinch).
    public static func userButtonsDown(left: Bool, right: Bool, center: Bool, ownCenterDown: Bool) -> Bool {
        left || right || (center && !ownCenterDown)
    }

    public static func decide(at p: CGPoint, windows: [WinInfo], buttonsDown: Bool, context: DecideContext,
                              log: TrackpadLog? = nil, displays: [CGRect] = []) -> Target? {
        guard !buttonsDown else { log?.lineOnChange("pass: a mouse button is held"); return nil }
        let pids = Set(context.revits.keys)
        guard let w = WindowPick.top(at: p, frontToBack: windows, revitPids: pids, displays: displays) else {
            log?.lineOnChange("pass: no window there")
            return nil
        }
        guard let r = context.revits[w.pid] else {
            log?.lineOnChange("pass: \(w.owner.isEmpty ? "another app" : w.owner)'s window over the point (layer \(w.layer))")
            return nil
        }
        let pid = w.pid
        guard case .ready(let s) = r.client.status else { log?.line("pass: \(r.bottle) not ready"); return nil }
        guard let reply = r.client.query(DisplayMap.toWine(p, scale: s)) else { log?.line("pass: \(r.bottle) no answer"); return nil }
        let view = ViewRule.isView(year: r.year, reply: reply)
        log?.line("\(view ? "view" : "pass") \(reply.chain.first?.cls ?? "(no window)")")
        return view ? Target(pid: pid) : nil
    }
}
