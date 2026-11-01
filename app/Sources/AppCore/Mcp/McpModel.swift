// The AI Assistant tab. Whatever gives an assistant access goes through GrantGate first: the system asks the person, so
// a program that only clicks in this app does not get through.
import Foundation

public enum Grant: Equatable, Sendable { case allowed, refused(String) }

@MainActor public protocol GrantGate {
    func ask(_ reason: String) async -> Grant
}

@MainActor @Observable public final class McpModel {
    public private(set) var servers: [McpServerInfo] = []
    public private(set) var tokens: [McpToken] = []
    public private(set) var calls: [McpCall] = []
    public private(set) var problem: String?
    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private let gate: any GrantGate
    public let year: Int
    public let bottle: String

    public init(app: AppModel, gate: any GrantGate, year: Int, bottle: String) {
        self.app = app; self.gate = gate; self.year = year; self.bottle = bottle
    }

    private func answer<T: Decodable>(_ args: [String], _ type: T.Type) async -> T? {
        guard let out = await app.query(args), out.exitCode == 0 else { return nil }
        return try? JSONDecoder.engine.decode(T.self, from: out.stdout)
    }

    public func load() async {
        let y = String(year)
        if let s = await answer(["mcp", "servers", y, bottle, "--json"], McpServers.self) { servers = s.servers }
        if let t = await answer(["mcp", "tokens", "--json"], McpTokens.self) { tokens = t.tokens.filter { $0.bottle == bottle } }
        if let c = await answer(["mcp", "log", y, bottle, "--json"], McpCalls.self) { calls = c.calls.reversed() }
    }

    public func revoke(_ name: String) async {
        let out = await app.query(["mcp", "revoke", name])
        problem = out?.exitCode == 0 ? nil : (out?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? app.engineError)
        await load()
    }

    public enum IssueOutcome: Equatable, Sendable { case issued(McpIssued), refused(String) }

    /// The order counts: a Desktop bundle first, so nothing that can fail after it leaves a token no one saw; the log's
    /// line before the token is shown, and without that line no token stays.
    public func issue(server s: McpServerInfo, tier: String, client: McpClient) async -> IssueOutcome {
        guard let data = app.dataFolder else { return .refused(String(localized: "The data folder is not known yet.")) }
        let name = client.tokenName(bottle: bottle, server: s.id)
        guard case .allowed = await gateAnswer(String(localized: "give an AI assistant access to Revit \(String(year)) (\(s.name), \(tier))")) else {
            return .refused(lastRefusal)
        }
        var path: String?
        if client == .claudeDesktop {
            guard let b = await answer(["mcp", "bundle-file", String(year), bottle, "--server", s.id], BundleFile.self) else {
                return .refused(String(localized: "Could not make the file for Claude Desktop."))
            }
            path = b.path
        }
        let store = TokenStore(data: data)
        let value: String
        do { value = try store.add(name: name, year: year, bottle: bottle, server: s.id, tier: tier) }
        catch { return .refused("\(error)") }
        let note = await app.query(["mcp", "note-created", String(year), bottle, "--server", s.id, "--name", name, "--tier", tier])
        guard note?.exitCode == 0 else {
            try? store.remove(name: name, sha256: TokenStore.sha256(value))
            return .refused(note?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? String(localized: "Could not write the log of MCP calls."))
        }
        await load()
        let add = (["claude", "mcp", "add", s.claudeName, "-e", "REVIT_MCP_TOKEN=\(value)", "--", s.engine] + s.args).map(\.shellQuoted).joined(separator: " ")
        return .issued(McpIssued(token: value, name: name, client: client, addCommand: add,
                                 removeCommand: "claude mcp remove \(s.claudeName.shellQuoted)", bundle: path))
    }

    /// ./revit agent-view after the same question: computer use tools then see the running Revit.
    public func showToAgent() async -> Result<String, TokenStoreError> {
        guard case .allowed = await gateAnswer(String(localized: "let computer use tools see and press Revit \(String(year))")) else {
            return .failure(TokenStoreError(lastRefusal))
        }
        guard let out = await app.query(["agent-view", String(year), bottle]) else { return .failure(TokenStoreError(app.engineError ?? "")) }
        let t = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return out.exitCode == 0 ? .success(t(String(decoding: out.stdout, as: UTF8.self))) : .failure(TokenStoreError(t(out.stderr)))
    }

    @ObservationIgnored private var lastRefusal = ""

    private func gateAnswer(_ reason: String) async -> Grant {
        let g = await gate.ask(reason)
        if case .refused(let why) = g { lastRefusal = why }
        return g
    }

    private struct BundleFile: Decodable { let path: String }
}
