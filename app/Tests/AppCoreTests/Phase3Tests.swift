// The AI Assistant tab: nothing is granted before the system has asked, and a token never stays half made.
import Foundation
import Testing
@testable import AppCore

@MainActor private final class FakeGrant: GrantGate {
    var answer = Grant.allowed
    var asked: [String] = []
    func ask(_ reason: String) async -> Grant { asked.append(reason); return answer }
}

@MainActor @Suite struct Phase3Tests {
    private let info = McpServerInfo(id: "ui", name: "Revit's windows", state: "ready", missing: "", note: "", tiers: ["read", "write"],
                                     claudeName: "revit-b-ui", engine: "/Apps/My App/revit", args: ["mcp", "2027", "b", "--server", "ui"])
    private func ok(_ s: String = "") -> EngineOutput { EngineOutput(stdout: Data(s.utf8), stderr: "", exitCode: 0) }
    private func world() throws -> (FakeEngine, AppModel, FakeGrant, McpModel, URL) {
        let d = FileManager.default.temporaryDirectory.appending(path: "mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let e = FakeEngine(), g = FakeGrant()
        let a = AppModel(engine: e, defaults: TestDefaults.make(), notifier: FakeNotifier(), dataOverride: d)
        return (e, a, g, McpModel(app: a, gate: g, year: 2027, bottle: "b"), d)
    }
    private func tokens(_ d: URL) -> [[String: Any]] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: d.appending(path: "mcp/tokens.json")))) as? [[String: Any]] ?? []
    }
    private let note = ["mcp", "note-created", "2027", "b", "--server", "ui", "--name", "claude-code-b-ui", "--tier", "read"]

    @Test func noConfirmationNoToken() async throws {
        let (e, _, g, m, d) = try world()
        g.answer = .refused("Canceled")
        #expect(await m.issue(server: info, tier: "read", client: .claudeCode) == .refused("Canceled"))
        #expect(tokens(d).isEmpty)
        #expect(await e.calls.isEmpty)
    }

    @Test func aTokenIsMadeAfterAskingAndNoEngineCallCarriesIt() async throws {
        let (e, _, g, m, d) = try world()
        await e.set(query: note, ok())
        guard case .issued(let i) = await m.issue(server: info, tier: "read", client: .claudeCode) else { Issue.record("no token"); return }
        #expect(g.asked.count == 1)
        let row = try #require(tokens(d).first)
        #expect(row["sha256"] as? String == TokenStore.sha256(i.token) && row["year"] as? String == "2027" && row["server"] as? String == "ui")
        #expect(row["tier"] as? String == "read" && i.name == "claude-code-b-ui")
        #expect(i.addCommand.contains("'/Apps/My App/revit' mcp 2027 b --server ui"))
        #expect(await !e.calls.joined().contains(i.token))
        let mode = try FileManager.default.attributesOfItem(atPath: d.appending(path: "mcp/tokens.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func aTakenNameIsRefusedAndKept() async throws {
        let (e, _, _, m, d) = try world()
        await e.set(query: note, ok())
        _ = await m.issue(server: info, tier: "read", client: .claudeCode)
        let before = tokens(d).first?["sha256"] as? String
        guard case .refused = await m.issue(server: info, tier: "read", client: .claudeCode) else { Issue.record("replaced"); return }
        #expect(tokens(d).count == 1 && tokens(d).first?["sha256"] as? String == before)
    }

    @Test func noLogLineNoToken() async throws {
        let (e, _, _, m, d) = try world()
        await e.set(query: note, EngineOutput(stdout: Data(), stderr: "Cannot write the log", exitCode: 1))
        #expect(await m.issue(server: info, tier: "read", client: .claudeCode) == .refused("Cannot write the log"))
        #expect(tokens(d).isEmpty)
    }

    @Test func aBundleThatFailsLeavesNoToken() async throws {
        let (_, _, _, m, d) = try world()
        guard case .refused = await m.issue(server: info, tier: "read", client: .claudeDesktop) else { Issue.record("token"); return }
        #expect(tokens(d).isEmpty)
    }

    @Test func theRealGateAcceptsATokenMadeHere() throws {
        let d = FileManager.default.temporaryDirectory.appending(path: "mcp-\(UUID().uuidString)")
        let v = try TokenStore(data: d).add(name: "n", year: 2027, bottle: "b", server: "ui", tier: "write")
        let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../tools").standardizedFileURL.path
        let py = """
        import sys
        sys.path.insert(0, sys.argv[1])
        import mcp_gate as g
        r = g.find_token(g.load_tokens(sys.argv[2]), g.token_sha(sys.argv[3]), "b", "ui")
        sys.exit(0 if r and r["tier"] == "write" and r["year"] == "2027" else 1)
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-B", "-c", py, tools, d.path, v]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func aDamagedFileIsNotOverwritten() throws {
        let d = FileManager.default.temporaryDirectory.appending(path: "mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d.appending(path: "mcp"), withIntermediateDirectories: true)
        try Data("[{\"sha256\":\"x\"}]".utf8).write(to: d.appending(path: "mcp/tokens.json"))
        #expect(throws: TokenStoreError.self) { _ = try TokenStore(data: d).add(name: "n", year: 2027, bottle: "b", server: "ui", tier: "read") }
    }

    @Test func showingRevitAsksFirst() async throws {
        let (e, _, g, m, _) = try world()
        g.answer = .refused("No")
        guard case .failure = await m.showToAgent() else { Issue.record("shown"); return }
        #expect(await e.calls.isEmpty)
    }

    @Test func tabIsOnEveryBottleAndDecodes() throws {
        #expect(VersionTab.of(nil).contains(.ai))
        let d = Data(#"{"calls":[{"ts":"1","tool":"t","ms":null,"outcome":"no_answer","token":null,"client":null}]}"#.utf8)
        #expect(try JSONDecoder.engine.decode(McpCalls.self, from: d).calls[0].outcome == "no_answer")
        #expect("a b'c".shellQuoted == #"'a b'"'"'c'"#)
    }
}
