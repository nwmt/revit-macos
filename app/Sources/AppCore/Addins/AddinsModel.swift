// The add-ins window of one bottle (spec §3): the engine's catalog for its year, what is installed in that bottle,
// the files the user must bring (addins import), the licenses to accept, the tool an add-in needs, and one run that
// installs the selected add-ins (addins --only). The MVP only adds: installed rows have no checkbox.
import Foundation
import Observation

public enum AddinState: Equatable, Sendable { case installed, available, needsFile, needsTool(brew: Bool) }

public struct AddinRow: Equatable, Sendable {
    public let id, name, about: String
    public let tested: Bool
    public let eula: String
    public let notice: String                // shown with the license before consent, or ""
    public let tool: String                  // a tool it needs on this Mac (gs), or ""
    public let state: AddinState
}

@MainActor @Observable public final class AddinsModel {
    @ObservationIgnored let app: AppModel
    @ObservationIgnored let system: any SystemActions
    public let year: Int
    public let bottle: String
    public private(set) var rows: [AddinRow] = []
    public private(set) var error: String?
    public private(set) var selected: Set<String> = []
    public private(set) var accepted: Set<String> = []
    public private(set) var working = false
    /// The Homebrew formula of an add-in's tool.
    static let formulas = ["gs": "ghostscript"]

    public init(app: AppModel, system: any SystemActions, year: Int, bottle: String) {
        self.app = app; self.system = system; self.year = year; self.bottle = bottle
    }

    /// addins list <year> --json, then the bottle's installed add-ins from a fresh status.
    public func load() async {
        guard let out = await app.query(["addins", "list", String(year), "--json"]) else { error = app.engineError; return }
        guard out.exitCode == 0, let list = try? JSONDecoder.engine.decode([AddinInfo].self, from: out.stdout) else {
            error = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines); return
        }
        await app.refresh()
        let installed = Set(app.status?.bottles.first { $0.name == bottle }?.addins ?? [])
        let brew = system.brew() != nil
        rows = list.filter(\.available).map { a in
            let state: AddinState
            if installed.contains(a.id) { state = .installed }
            else if a.source == "own" && !a.ready { state = .needsFile }
            else if !a.tool.isEmpty && !a.toolOk { state = .needsTool(brew: brew) }
            else { state = .available }
            return AddinRow(id: a.id, name: a.name, about: a.about, tested: a.tested, eula: a.eula, notice: a.notice,
                            tool: a.tool, state: state)
        }
        selected = selected.filter { id in rows.contains { $0.id == id && $0.state == .available } }
    }

    /// Selects or clears an available add-in. One with a license not yet accepted is not selected: its URL comes back
    /// for the license sheet.
    public func toggle(_ id: String) -> String? {
        guard let r = rows.first(where: { $0.id == id }), r.state == .available else { return nil }
        if selected.contains(id) { selected.remove(id); return nil }
        if !r.eula.isEmpty && !accepted.contains(id) { return r.eula }
        selected.insert(id)
        return nil
    }

    /// The user agreed in the license sheet.
    public func accept(_ id: String) {
        accepted.insert(id)
        if rows.contains(where: { $0.id == id && $0.state == .available }) { selected.insert(id) }
    }

    public func importFile(_ id: String, _ file: URL) async {
        error = nil
        working = true; defer { working = false }
        guard let out = await app.query(["addins", "import", id, file.path]) else { error = app.engineError; return }
        guard out.exitCode == 0 else { error = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines); return }
        await load()
    }

    public func installTool(_ id: String) async {
        guard let tool = rows.first(where: { $0.id == id })?.tool, let formula = Self.formulas[tool] else { return }
        error = nil
        working = true; defer { working = false }
        let logs = (app.dataFolder ?? FileManager.default.temporaryDirectory).appending(path: "logs/app")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        do { try await system.brewInstall(["install", formula], log: logs.appending(path: "brew-\(f.string(from: Date())).log")) }
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        await load()
    }

    /// The selected add-ins in catalog order, with the licenses accepted for them; nothing selected: no run.
    public func installSelected() async throws {
        let ids = rows.map(\.id).filter { selected.contains($0) }
        guard !ids.isEmpty else { return }
        try await app.start(.addins(year: year, bottle: bottle, ids: ids, eula: ids.filter { accepted.contains($0) }))
        selected = []
    }

}
