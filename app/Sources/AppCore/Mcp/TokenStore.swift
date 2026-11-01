// A token the app makes itself, after the system asked the person (GrantGate). It writes the file tools/mcp_gate.py reads:
// mcp/tokens.json under flock on mcp/tokens.lock, the same format, the same modes. ./revit mcp token keeps its terminal:
// there is no way to this from the command line, so an agent's way is no easier than before.
import CryptoKit
import Darwin
import Foundation
import Security

public struct TokenStoreError: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

public struct TokenStore: Sendable {
    let data: URL
    public init(data: URL) { self.data = data }

    private var dir: URL { data.appending(path: "mcp") }
    private var file: URL { dir.appending(path: "tokens.json") }

    public static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// As secrets.token_urlsafe(32).
    static func newValue() throws -> String {
        var b = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, b.count, &b) == errSecSuccess else { throw TokenStoreError("No random bytes.") }
        return Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        let fd = open(dir.appending(path: "tokens.lock").path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw TokenStoreError("Cannot open the lock of the MCP tokens.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw TokenStoreError("Cannot lock the MCP tokens.") }
        return try body()
    }

    private func load() throws -> [[String: Any]] {
        guard let d = try? Data(contentsOf: file) else {
            if FileManager.default.fileExists(atPath: file.path) { throw TokenStoreError("Cannot read the MCP tokens.") }
            return []
        }
        guard let rows = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]],
              rows.allSatisfy({ ($0["sha256"] as? String)?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil })
        else { throw TokenStoreError("The file of MCP tokens is damaged.") }
        return rows
    }

    private func save(_ rows: [[String: Any]]) throws {
        let d = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let tmp = dir.appending(path: "tokens.json.tmp.\(getpid())")
        guard FileManager.default.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600]) else {
            throw TokenStoreError("Cannot write the MCP tokens.")
        }
        guard rename(tmp.path, file.path) == 0 else { throw TokenStoreError("Cannot write the MCP tokens.") }
    }

    /// A taken name is refused: the app never replaces a connection.
    public func add(name: String, year: Int, bottle: String, server: String, tier: String, now: Date = Date()) throws -> String {
        let value = try Self.newValue()
        try locked {
            var rows = try load()
            guard !rows.contains(where: { $0["name"] as? String == name }) else {
                throw TokenStoreError(String(localized: "This connection exists already. Revoke it first."))
            }
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
            rows.append(["name": name, "sha256": Self.sha256(value), "tier": tier, "bottle": bottle, "year": String(year),
                         "server": server, "created": f.string(from: now)])
            try save(rows)
        }
        return value
    }

    /// Takes back a token this app has just made: only that one, not one that has taken its name since.
    public func remove(name: String, sha256: String) throws {
        try locked {
            let rows = try load()
            let kept = rows.filter { !($0["name"] as? String == name && $0["sha256"] as? String == sha256) }
            if kept.count != rows.count { try save(kept) }
        }
    }
}
