// The Mac window under a point (spec §3): the windows from front to back, all layers; the first one that holds the
// point, is visible and has a size must be a known Revit's. A panel or another app's window over Revit: not Revit.
// The cursor does not count: a custom one (Revit's orbit cursor under Wine) is a small window of its own, at the
// cursor's layer, right at the point.
import CoreGraphics

public struct WinInfo: Sendable {
    public let pid: Int32
    public let bounds: CGRect
    public let alpha: Double
    public let layer: Int
    public init(pid: Int32, bounds: CGRect, alpha: Double, layer: Int = 0) {
        self.pid = pid; self.bounds = bounds; self.alpha = alpha; self.layer = layer
    }
}

public enum WindowPick {
    public static let cursorLayer = Int(CGWindowLevelForKey(.cursorWindow))

    public static func target(at p: CGPoint, frontToBack: [WinInfo], revitPids: Set<Int32>) -> Int32? {
        guard let w = frontToBack.first(where: {
            $0.layer < cursorLayer && $0.alpha > 0 && $0.bounds.width > 0 && $0.bounds.height > 0 && $0.bounds.contains(p)
        }) else { return nil }
        return revitPids.contains(w.pid) ? w.pid : nil
    }
}
