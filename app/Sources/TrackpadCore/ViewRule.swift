// Which Windows window is a Revit view (spec §5). Closed by default: only years checked in Revit are in the table, so
// in another year two-finger scrolling stays scrolling. Schedules scroll too: no parent may be titled "Schedule…"
// (Revit is installed in English). A cut or untitled chain is not a view: too little is known.
public enum ViewRule {
    public static let classes: [Int: Set<String>] = [2027: ["AfxFrameOrView140u"]]

    public static func isView(year: Int, reply: HitReply) -> Bool {
        guard let cls = classes[year], !reply.bad, reply.complete, let first = reply.chain.first, cls.contains(first.cls)
        else { return false }
        let parents = reply.chain.dropFirst()
        guard parents.contains(where: { !$0.title.isEmpty }) else { return false }
        return !parents.contains { $0.title.hasPrefix("Schedule") }
    }
}
