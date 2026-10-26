// hittest.exe's protocol, version 1 (tools/shims/hittest/hittest.c has the full text):
//   > hello 1 0 0 3024 1964
//   < 7 1512 900
//   > 7<TAB>AfxFrameOrView140u<TAB><TAB>AfxMDIFrame140u<TAB>Floor Plan: L1<TAB>…<TAB>.
//   > 8<TAB>.            no window          > 0<TAB>?            not a request
import CoreGraphics
import Foundation

public struct HitWindow: Equatable, Sendable {
    public let cls: String
    public let title: String
    public init(cls: String, title: String) { self.cls = cls; self.title = title }
}

public struct HitReply: Equatable, Sendable {
    public let seq: Int
    public let chain: [HitWindow]           // the window under the point first, then its parents
    public let complete: Bool               // false: cut at 8 levels (or a bad line)
    public let bad: Bool                    // hittest did not take the request
    public init(seq: Int, chain: [HitWindow], complete: Bool, bad: Bool) {
        self.seq = seq; self.chain = chain; self.complete = complete; self.bad = bad
    }
}

public enum HittestProtocol {
    public static func hello(_ line: String) -> CGRect? {
        let f = line.split(separator: " ", omittingEmptySubsequences: false)
        guard f.count == 6, f[0] == "hello", f[1] == "1" else { return nil }
        let n = f[2...].compactMap { Int($0) }
        guard n.count == 4 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    public static func reply(_ line: String) -> HitReply? {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 2, let seq = Int(f[0]) else { return nil }
        let end = f[f.count - 1], pairs = f[1..<(f.count - 1)]
        if end == "?" { return pairs.isEmpty ? HitReply(seq: seq, chain: [], complete: false, bad: true) : nil }
        guard end == "." || end == "+", pairs.count % 2 == 0 else { return nil }
        let a = Array(pairs)
        let chain = stride(from: 0, to: a.count, by: 2).map { HitWindow(cls: a[$0], title: a[$0 + 1]) }
        return HitReply(seq: seq, chain: chain, complete: end == ".", bad: false)
    }

    public static func request(seq: Int, x: Int, y: Int) -> String { "\(seq) \(x) \(y)\n" }
}

public enum LineEvent: Equatable, Sendable { case line(String), overflow }

/// Splits hittest's output into lines. A line over TrackpadConstants.maxLine bytes is one .overflow, then skipped up to
/// its newline.
public struct LineBuffer {
    private var buf = Data()
    private var skipping = false
    public init() {}

    public mutating func append(_ d: Data) -> [LineEvent] {
        var out: [LineEvent] = []
        for b in d {
            if b == 10 {
                if !skipping { out.append(.line(String(decoding: buf, as: UTF8.self))) }
                buf.removeAll(keepingCapacity: true); skipping = false
            } else if skipping {
                continue
            } else if buf.count == TrackpadConstants.maxLine {
                out.append(.overflow); buf.removeAll(keepingCapacity: true); skipping = true
            } else {
                buf.append(b)
            }
        }
        return out
    }
}
