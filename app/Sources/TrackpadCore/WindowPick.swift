// The Mac window under a point (spec §3): the windows from front to back, all layers; the first one that holds the
// point, is visible and has a size must be a known Revit's. A panel or another app's window over Revit: not Revit.
import CoreGraphics

public struct WinInfo: Sendable {
    public let pid: Int32
    public let bounds: CGRect
    public let alpha: Double
    public init(pid: Int32, bounds: CGRect, alpha: Double) { self.pid = pid; self.bounds = bounds; self.alpha = alpha }
}

public enum WindowPick {
    public static func target(at p: CGPoint, frontToBack: [WinInfo], revitPids: Set<Int32>) -> Int32? {
        guard let w = frontToBack.first(where: { $0.alpha > 0 && $0.bounds.width > 0 && $0.bounds.height > 0 && $0.bounds.contains(p) })
        else { return nil }
        return revitPids.contains(w.pid) ? w.pid : nil
    }
}
