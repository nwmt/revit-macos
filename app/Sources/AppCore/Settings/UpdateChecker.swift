// The daily update check: the project's GitHub releases, the app's own (tags app-vX.Y.Z), only a notification.
import Foundation

public struct Release: Equatable, Sendable {
    public let version: String
    public let url: URL
}

public struct UpdateChecker: Sendable {
    let repo: String
    let current: String
    let fetch: @Sendable (URL) async throws -> Data

    public init(repo: String, current: String, fetch: @escaping @Sendable (URL) async throws -> Data) {
        self.repo = repo; self.current = current; self.fetch = fetch
    }

    struct GitHubRelease: Decodable { let tagName: String; let draft: Bool; let htmlUrl: String }

    /// The highest app release newer than the running app (pre-releases count: every app release is one for now).
    public func newer() async throws -> Release? {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=30")!
        let list = try JSONDecoder.engine.decode([GitHubRelease].self, from: try await fetch(url))
        var best: Release?
        for r in list where !r.draft {
            guard let m = r.tagName.wholeMatch(of: /app-v(\d+\.\d+\.\d+)/), let u = URL(string: r.htmlUrl) else { continue }
            let v = String(m.1)
            if Self.isNewer(v, than: best?.version ?? current) { best = Release(version: v, url: u) }
        }
        return best
    }

    /// X.Y.Z compared as numbers; anything else is never newer.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parts(a), let y = parts(b) else { return false }
        return x.lexicographicallyPrecedes(y) == false && x != y
    }

    static func parts(_ s: String) -> [Int]? {
        let p = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard p.count == 3, p.allSatisfy({ $0 != nil }), s.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return p.compactMap { $0 }
    }

    /// Never checked, or the last check is a day old.
    public static func due(last: Date?, now: Date) -> Bool { last.map { now.timeIntervalSince($0) >= 24 * 3600 } ?? true }
}
