// The Mac window under a point (spec §3): the windows from front to back, all layers; the first one that holds the
// point, is visible and has a size must be a known Revit's. A panel or another app's window over Revit: not Revit.
// The cursor does not count: a custom one (Revit's orbit cursor under Wine) is a small window of its own, at the
// cursor's layer, right at the point. Neither does another app's window above the normal layer that fills a display:
// macOS keeps invisible ones there (the Dock's, screencaptureui's, hours long), and clicks go through them to Revit.
import CoreGraphics

public struct WinInfo: Sendable {
    public let pid: Int32
    public let bounds: CGRect
    public let alpha: Double
    public let layer: Int
    public let owner: String   // the app's name, for the log
    public init(pid: Int32, bounds: CGRect, alpha: Double, layer: Int = 0, owner: String = "") {
        self.pid = pid; self.bounds = bounds; self.alpha = alpha; self.layer = layer; self.owner = owner
    }
}

public enum WindowPick {
    public static let cursorLayer = Int(CGWindowLevelForKey(.cursorWindow))

    /// The window that decides for the point: nil when there is none.
    public static func top(at p: CGPoint, frontToBack: [WinInfo], revitPids: Set<Int32>, displays: [CGRect] = []) -> WinInfo? {
        frontToBack.first(where: {
            $0.layer < cursorLayer && $0.alpha > 0 && $0.bounds.width > 0 && $0.bounds.height > 0 && $0.bounds.contains(p) &&
                !($0.layer > 0 && !revitPids.contains($0.pid) && displays.contains($0.bounds))
        })
    }

    public static func target(at p: CGPoint, frontToBack: [WinInfo], revitPids: Set<Int32>, displays: [CGRect] = []) -> Int32? {
        guard let w = top(at: p, frontToBack: frontToBack, revitPids: revitPids, displays: displays) else { return nil }
        return revitPids.contains(w.pid) ? w.pid : nil
    }
}
