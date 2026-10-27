// Mac points to Wine pixels. Wine's Mac driver scales every screen by one factor (2 while Retina mode is active, else
// 1), so the factor is not read from the bottle's settings but found: hittest's virtual screen must be the union of the
// Mac's screens times that factor, origin and size, within one pixel per point.
import CoreGraphics

public struct WinePoint: Equatable, Sendable {
    public let x: Int, y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

public enum DisplayMap {
    public static func scale(hello: CGRect, cgUnion: CGRect) -> Int? {
        for s in [1, 2] {
            let f = CGFloat(s), tol = f
            let want = [cgUnion.minX * f, cgUnion.minY * f, cgUnion.width * f, cgUnion.height * f]
            let got = [hello.minX, hello.minY, hello.width, hello.height]
            if zip(want, got).allSatisfy({ abs($0 - $1) <= tol }) { return s }
        }
        return nil
    }

    public static func toWine(_ p: CGPoint, scale: Int) -> WinePoint {
        WinePoint(x: Int((p.x * CGFloat(scale)).rounded(.down)), y: Int((p.y * CGFloat(scale)).rounded(.down)))
    }
}
