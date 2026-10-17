// The first-run wizard (spec §3): Rosetta, CrossOver, msls31.dll, the installer folder,
// the check, the install. Every row reads the engine's status or answer; a check counts only for the inputs it
// checked (year, folder, bottle name, source choice), and install needs a passed check of the current inputs.
import Foundation
import Observation

public enum WizardRow: CaseIterable, Sendable { case rosetta, crossover, msls31, installer, check, install }

public enum RowState: Equatable, Sendable { case done(String), warning(String), open, waiting, working, failed(String) }

public struct InstallerChoice: Equatable, Sendable {
    public let folder: URL
    public let info: InstallerInfo
    public let year: Int
}

public enum WizardError: Error, Equatable { case notReady }

/// The inputs a check ran with.
struct CheckKey: Equatable { let year: Int; let folder: String; let bottle: String; let source: SourceChoice? }

@MainActor @Observable public final class WizardModel {
    @ObservationIgnored let app: AppModel
    @ObservationIgnored let system: any SystemActions

    public private(set) var installer: InstallerChoice?
    public var bottleName = "" { didSet { if bottleName != oldValue { forgetCheck() } } }
    public private(set) var source: SourceChoice?
    public private(set) var crossoverNote: String?

    private var working: Set<WizardRow> = []
    private var errors: [WizardRow: String] = [:]
    private var checkKey: CheckKey?        // the inputs of the check started last
    private var checkCtx: URL?             // its run folder
    private var outcome: (state: RowState, warnings: [String], mismatch: Bool)?

    public init(app: AppModel, system: any SystemActions) { self.app = app; self.system = system }

    // MARK: rows

    public func state(_ row: WizardRow) -> RowState {
        if working.contains(row) { return .working }
        if let e = errors[row] { return .failed(e) }
        let s = app.status
        switch row {
        case .rosetta:
            return s?.rosetta == true ? .done(String(localized: "Rosetta is installed")) : .open
        case .crossover:
            guard let c = s?.crossover, c.found else { return .open }
            return c.supported ? .done(String(localized: "CrossOver \(c.version)"))
                : .warning(String(localized: "CrossOver \(c.version): this app is tested with CrossOver 26"))
        case .msls31:
            return s?.msls31 == true ? .done(String(localized: "msls31.dll is in place")) : .open
        case .installer:
            guard let i = installer else { return .open }
            return .done(i.info.complete ? String(localized: "Revit \(String(i.year)): all files here")
                         : String(localized: "Revit \(String(i.year)): the rest is downloaded at install"))
        case .check:
            return checkState()
        case .install:
            if case .done = checkState(), !app.isBusy { return .open }
            return .waiting
        }
    }

    /// The first row that is open or failed; a warning counts as done.
    public var firstOpen: WizardRow? {
        WizardRow.allCases.first { switch state($0) { case .open, .failed: true; default: false } }
    }

    public var busyText: String? { app.busyText }
    public var checkWarnings: [String] { currentOutcome()?.warnings ?? [] }
    /// The check found the unpacked installer is from another one: offer "Use the existing one" / "Unpack again".
    public var offersSourceChoice: Bool { currentOutcome()?.mismatch ?? false }

    var nameOK: Bool { bottleName.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil }

    var currentKey: CheckKey? {
        installer.map { CheckKey(year: $0.year, folder: $0.folder.path, bottle: bottleName, source: source) }
    }

    private func checkState() -> RowState {
        guard installer != nil, nameOK else { return .waiting }
        if let ctx = checkCtx, checkKey == currentKey, let w = app.watched, w.ctx == ctx, w.phase == .running || w.phase == .finishing {
            return .working
        }
        if app.isBusy { return .waiting }
        if let o = currentOutcome() { return o.state }
        return .open
    }

    /// The result of the last check, when it checked the current inputs and has ended.
    private func currentOutcome() -> (state: RowState, warnings: [String], mismatch: Bool)? {
        guard checkKey != nil, checkKey == currentKey else { return nil }
        if let o = outcome { return o }
        guard let ctx = checkCtx, let w = app.watched, w.ctx == ctx else { return nil }
        let errs = w.state.messages.filter { $0.level == "error" }.map(\.text)
        let o: (state: RowState, warnings: [String], mismatch: Bool)
        switch (w.phase, w.state.end?.kind) {
        case (.ended, .ok?):
            o = (.done(String(localized: "Ready")), w.state.messages.filter { $0.level == "warn" }.map(\.text), false)
        case (.ended, .sourceMismatch?):
            o = (.failed(errs.last ?? ""), [], true)
        case (.ended, _):
            let text = errs.isEmpty ? Failure.lastLines(AppModel.text(ctx.appending(path: "console.log")), 3) : errs.joined(separator: "\n")
            o = (.failed(text), [], false)
        case (.interrupted, _):
            o = (.failed(String(localized: "The check was interrupted.")), [], false)
        default:
            return nil
        }
        outcome = o
        return o
    }

    private func forgetCheck() { checkKey = nil; checkCtx = nil; outcome = nil; errors[.check] = nil }

    // MARK: actions

    public func installRosetta() async {
        await act(.rosetta) { try await self.system.installRosetta() }
        await app.refresh()
    }

    public func installCrossOver() async {
        guard let _ = system.brew() else {
            system.open(URL(string: "https://www.codeweavers.com/crossover")!)
            crossoverNote = String(localized: "Install CrossOver, then come back here.")
            return
        }
        let logs = (app.dataFolder ?? FileManager.default.temporaryDirectory).appending(path: "logs/app")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        let log = logs.appending(path: "brew-\(f.string(from: Date())).log")
        await act(.crossover) { try await self.system.brewInstall(["install", "--cask", "crossover"], log: log) }
        await app.refresh()
    }

    public func importMsls31(_ file: URL) async {
        errors[.msls31] = nil
        working.insert(.msls31); defer { working.remove(.msls31) }
        guard let out = await app.query(["import", "msls31", file.path]) else { errors[.msls31] = app.engineError ?? ""; return }
        guard out.exitCode == 0 else { errors[.msls31] = Self.trimmed(out.stderr); return }
        await app.refresh()
    }

    public func chooseInstaller(_ folder: URL) async {
        installer = nil; errors[.installer] = nil; forgetCheck()
        working.insert(.installer); defer { working.remove(.installer) }
        guard let out = await app.query(["find-installer", folder.path, "--json"]) else { errors[.installer] = app.engineError ?? ""; return }
        guard out.exitCode == 0, let info = try? JSONDecoder.engine.decode(InstallerInfo.self, from: out.stdout) else {
            errors[.installer] = Self.trimmed(out.stderr); return
        }
        guard let ys = info.year, let year = Int(ys) else { errors[.installer] = String(localized: "No Revit installer found in this folder."); return }
        if let bad = info.files.first(where: { $0.check == "mismatch" }) {
            errors[.installer] = String(localized: "\(bad.name) does not match its checksum. Download it again from your Autodesk Account."); return
        }
        guard info.complete || info.downloadable else {
            errors[.installer] = String(localized: "Missing: \(info.missing.joined(separator: ", "))"); return
        }
        guard let link = await app.query(["link-installer", String(year), folder.path]) else { errors[.installer] = app.engineError ?? ""; return }
        guard link.exitCode == 0 else { errors[.installer] = Self.trimmed(link.stderr); return }
        installer = InstallerChoice(folder: folder, info: info, year: year)
        bottleName = proposedName(year)
    }

    /// rvt<year>-a, or the first rvt<year>-<b…z> no bottle has.
    func proposedName(_ year: Int) -> String {
        let taken = Set((app.status?.bottles ?? []).map(\.name))
        return "abcdefghijklmnopqrstuvwxyz".map { "rvt\(year)-\($0)" }.first { !taken.contains($0) } ?? "rvt\(year)-a"
    }

    public func runCheck() async {
        guard let i = installer, nameOK, let key = currentKey else { return }
        forgetCheck()
        checkKey = key
        do {
            try await app.start(.check(year: i.year, bottle: bottleName, source: source))
            if checkKey == key { checkCtx = app.watched?.ctx }
        } catch {
            if checkKey == key { errors[.check] = app.engineError ?? (app.isBusy ? (app.busyText ?? "") : "\(error)") }
        }
    }

    public func choose(_ s: SourceChoice) async {
        source = s; forgetCheck()
        await runCheck()
    }

    public func install() async throws {
        guard case .open = state(.install), let i = installer else { throw WizardError.notReady }
        try await app.start(.install(year: i.year, bottle: bottleName, source: source))
        reset()   // the install runs in the progress window; the wizard is ready for the next version
    }

    /// Back to the start: no installer, no name, no source choice, no check.
    public func reset() {
        installer = nil; source = nil; crossoverNote = nil; errors = [:]
        bottleName = ""
        forgetCheck()
    }

    private func act(_ row: WizardRow, _ f: () async throws -> Void) async {
        errors[row] = nil
        working.insert(row); defer { working.remove(row) }
        do { try await f() } catch { errors[row] = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
    }

    static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
