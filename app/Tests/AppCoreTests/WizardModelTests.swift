// The first-run wizard: six rows, each from the engine's status or answer; a check that belongs to the inputs it
// checked; install only after that check passed.
import Foundation
import Testing
@testable import AppCore

/// A status --json answer with the wizard's facts.
func wizardStatus(rosetta: Bool = true, found: Bool = true, version: String = "26.3.0", supported: Bool = true, msls31: Bool = true,
                  bottles: [String] = [], busy: Bool = false) -> EngineOutput {
    let b = bottles.map { #"{"name":"\#($0)","year":"2025","revit":true,"running":false,"addins":[]}"# }.joined(separator: ",")
    let json = """
    {"crossover":{"found":\(found),"path":"/x","version":"\(version)","supported":\(supported)},"rosetta":\(rosetta),"msls31":\(msls31),\
    "busy":{"busy":\(busy),"command":"\(busy ? "install.sh 2026 rvt2026-a" : "")","run_id":"","pid":"","pid_start":"","pgid":"","ctx":""},"bottles":[\(b)]}
    """
    return EngineOutput(stdout: Data(json.utf8), stderr: "", exitCode: 0)
}
func out(_ s: String, exit: Int32 = 0, err: String = "") -> EngineOutput { EngineOutput(stdout: Data(s.utf8), stderr: err, exitCode: exit) }
let okInstaller = #"{"year": "2025", "kind": "create-installer", "complete": false, "downloadable": true, "missing": ["RVT_2025_B_002_002.7z"], "problem": "", "files": [{"name": "Create_Installer_RVT_2025_5_English_WIN64.exe", "check": "unknown"}]}"#
let checkEnd = #"{"event":"end","exit_code":0,"result":"ok","failed_action":"","failed_steps":[],"log_dir":""}"#
let mismatchEnd = #"{"event":"end","exit_code":1,"result":"source_mismatch","failed_action":"","failed_steps":[],"log_dir":""}"#

@MainActor final class WizardHarness {
    let h = Harness()
    let system = FakeSystem()
    lazy var wizard = WizardModel(app: h.model, system: system)
    let folder = URL(fileURLWithPath: "/tmp/Revit Installer")

    func status(_ o: EngineOutput) async { await h.fake.setStatus([o]); await h.model.refresh() }
    func installerReady(_ path: URL? = nil) async {
        let p = (path ?? folder).path
        await h.fake.set(query: ["find-installer", p, "--json"], out(okInstaller))
        await h.fake.set(query: ["link-installer", "2025", p], out("Revit 2025 installer: \(p)\n"))
        await wizard.chooseInstaller(path ?? folder)
    }
    /// Runs the check and lets it end with these events.
    func check(_ lines: [String]) async {
        await wizard.runCheck()
        await h.fake.emit(lines)
        await h.model.poll()
    }
}

@MainActor @Suite(.serialized) struct WizardModelTests {

    @Test func rowsFollowStatus() async {
        let w = WizardHarness()
        await w.status(wizardStatus(rosetta: false))
        #expect(w.wizard.firstOpen == .rosetta); #expect(w.wizard.state(.rosetta) == .open)
        await w.status(wizardStatus(msls31: false))
        #expect(w.wizard.firstOpen == .msls31)
        if case .done = w.wizard.state(.crossover) {} else { Issue.record("crossover not done") }
        await w.status(wizardStatus(version: "25.1.0", supported: false, msls31: false))
        #expect(w.wizard.state(.crossover) == .warning("CrossOver 25.1.0: this app is tested with CrossOver 26"))
        #expect(w.wizard.firstOpen == .msls31)
        await w.status(wizardStatus(found: false))
        #expect(w.wizard.firstOpen == .crossover)
        await w.status(wizardStatus())
        #expect(w.wizard.firstOpen == .installer); #expect(w.wizard.state(.check) == .waiting); #expect(w.wizard.state(.install) == .waiting)
    }

    @Test func installRosettaCallsTheSystemAndRefreshes() async {
        let w = WizardHarness()
        await w.h.fake.setStatus([wizardStatus(rosetta: false), wizardStatus(rosetta: true)])
        await w.h.model.refresh()
        await w.wizard.installRosetta()
        #expect(w.system.calls == ["rosetta"]); if case .done = w.wizard.state(.rosetta) {} else { Issue.record("not done") }
    }

    @Test func aRefusedPasswordIsAFailedRow() async {
        let w = WizardHarness()
        await w.status(wizardStatus(rosetta: false))
        w.system.rosettaError = "User canceled."
        await w.wizard.installRosetta()
        #expect(w.wizard.state(.rosetta) == .failed("User canceled.")); #expect(w.wizard.firstOpen == .rosetta)
    }

    @Test func installCrossOverWithBrew() async {
        let w = WizardHarness()
        await w.status(wizardStatus(found: false))
        w.system.brewPath = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        await w.wizard.installCrossOver()
        #expect(w.system.brewArgs == [["install", "--cask", "crossover"]]); #expect(w.system.opened.isEmpty)
    }

    @Test func installCrossOverWithoutBrewOpensTheDownloadPage() async {
        let w = WizardHarness()
        await w.status(wizardStatus(found: false))
        await w.wizard.installCrossOver()
        #expect(w.system.opened == [URL(string: "https://www.codeweavers.com/crossover")!]); #expect(w.system.brewArgs.isEmpty)
        #expect(w.wizard.crossoverNote == "Install CrossOver, then come back here.")
    }

    @Test func importMsls31RunsImport() async {
        let w = WizardHarness()
        await w.status(wizardStatus(msls31: false))
        await w.h.fake.set(query: ["import", "msls31", "/tmp/x/msls31.dll"], out("", exit: 1, err: "This is not the 64-bit msls31.dll.\n"))
        await w.wizard.importMsls31(URL(fileURLWithPath: "/tmp/x/msls31.dll"))
        #expect(await w.h.fake.calls.contains("run import msls31 /tmp/x/msls31.dll"))
        #expect(w.wizard.state(.msls31) == .failed("This is not the 64-bit msls31.dll."))
        await w.h.fake.set(query: ["import", "msls31", "/tmp/x/msls31.dll"], out("msls31.dll is ready.\n"))
        await w.h.fake.setStatus([wizardStatus(msls31: true)])
        await w.wizard.importMsls31(URL(fileURLWithPath: "/tmp/x/msls31.dll"))
        if case .done = w.wizard.state(.msls31) {} else { Issue.record("not done") }
    }

    enum Pick: CaseIterable, Sendable { case noYear, mismatch, missing, linkRefused }

    @Test(arguments: Pick.allCases) func chooseInstallerRefuses(_ c: Pick) async {
        let w = WizardHarness()
        await w.status(wizardStatus())
        let p = w.folder.path
        let find: String
        switch c {
        case .noYear: find = #"{"year": null, "kind": null, "complete": false, "downloadable": false, "missing": [], "problem": "", "files": []}"#
        case .mismatch: find = #"{"year": "2025", "kind": "archive", "complete": true, "downloadable": false, "missing": [], "problem": "", "files": [{"name": "RVT_2025_B_002_002.7z", "check": "mismatch"}]}"#
        case .missing: find = #"{"year": "2024", "kind": "parts", "complete": false, "downloadable": false, "missing": ["a_002_003.sfx.exe", "a_003_003.sfx.exe"], "problem": "", "files": []}"#
        case .linkRefused: find = okInstaller
        }
        await w.h.fake.set(query: ["find-installer", p, "--json"], out(find))
        await w.h.fake.set(query: ["link-installer", "2025", p], out("", exit: 1, err: "Another task is running: install.sh 2026 rvt2026-a. Wait until it finishes, then try again.\n"))
        await w.wizard.chooseInstaller(w.folder)
        let want: String
        switch c {
        case .noYear: want = "No Revit installer found in this folder."
        case .mismatch: want = "RVT_2025_B_002_002.7z does not match its checksum. Download it again from your Autodesk Account."
        case .missing: want = "Missing: a_002_003.sfx.exe, a_003_003.sfx.exe"
        case .linkRefused: want = "Another task is running: install.sh 2026 rvt2026-a. Wait until it finishes, then try again."
        }
        #expect(w.wizard.state(.installer) == .failed(want)); #expect(w.wizard.installer == nil)
    }

    @Test func chooseInstallerLinksAndProposesABottle() async {
        let w = WizardHarness()
        await w.status(wizardStatus())
        await w.installerReady()
        let runs = await w.h.fake.calls.filter { $0.hasPrefix("run ") }
        #expect(runs == ["run find-installer /tmp/Revit Installer --json", "run link-installer 2025 /tmp/Revit Installer"])
        #expect(w.wizard.state(.installer) == .done("Revit 2025: the rest is downloaded at install")); #expect(w.wizard.bottleName == "rvt2025-a")
        let w2 = WizardHarness()
        await w2.status(wizardStatus(bottles: ["rvt2025-a", "rvt2025-b"]))
        await w2.installerReady()
        #expect(w2.wizard.bottleName == "rvt2025-c")
    }

    @Test func runCheckOkListsWarnings() async {
        let w = WizardHarness()
        await w.status(wizardStatus())
        await w.installerReady()
        #expect(w.wizard.state(.check) == .open)
        await w.wizard.runCheck()
        #expect(w.wizard.state(.check) == .working)
        #expect(await w.h.fake.started.last == ["check", "2025", "rvt2025-a"])
        await w.h.fake.emit([#"{"event":"message","level":"warn","text":"only 20 GB free — an install needs up to ~55 GB (download, extracted files, bottle)"}"#, checkEnd])
        await w.h.model.poll()
        #expect(w.wizard.state(.check) == .done("Ready"))
        #expect(w.wizard.checkWarnings == ["only 20 GB free — an install needs up to ~55 GB (download, extracted files, bottle)"])
        #expect(w.wizard.state(.install) == .open)
    }

    @Test func runCheckSourceMismatchThenUnpackAgain() async throws {
        let w = WizardHarness()
        await w.status(wizardStatus())
        await w.installerReady()
        await w.check([#"{"event":"message","level":"error","text":"installers/extracted/revit2025 was unpacked from another installer — use it anyway or unpack again"}"#, mismatchEnd])
        #expect(w.wizard.state(.check) == .failed("installers/extracted/revit2025 was unpacked from another installer — use it anyway or unpack again"))
        #expect(w.wizard.offersSourceChoice)
        await w.wizard.choose(.reextract)
        #expect(await w.h.fake.started.last == ["check", "2025", "rvt2025-a", "--reextract"])
        await w.h.fake.emit([checkEnd]); await w.h.model.poll()
        #expect(w.wizard.state(.check) == .done("Ready"))
        try await w.wizard.install()
        #expect(await w.h.fake.started.last == ["install", "2025", "rvt2025-a", "--yes", "--reextract"])
    }

    @Test func aFailedCheckShowsTheEngineErrors() async {
        let w = WizardHarness()
        await w.status(wizardStatus())
        await w.installerReady()
        await w.check([#"{"event":"message","level":"error","text":"CrossOver not found — install it"}"#,
                       #"{"event":"message","level":"error","text":"bottle rvt2025-a already exists — pick another name"}"#,
                       #"{"event":"end","exit_code":1,"result":"failed","failed_action":"","failed_steps":[],"log_dir":""}"#])
        #expect(w.wizard.state(.check) == .failed("CrossOver not found — install it\nbottle rvt2025-a already exists — pick another name"))
        #expect(!w.wizard.offersSourceChoice)
    }

    @Test func aBadBottleNameKeepsCheckWaiting() async {
        let w = WizardHarness()
        await w.status(wizardStatus())
        await w.installerReady()
        w.wizard.bottleName = "my bottle"
        #expect(w.wizard.state(.check) == .waiting)
        await w.wizard.runCheck()
        #expect(await w.h.fake.started.isEmpty)
    }

    enum Change: CaseIterable, Sendable { case name, otherFolder, failingFolder, source }

    @Test(arguments: Change.allCases) func aReadyCheckIsUndoneByAnyChange(_ c: Change) async {
        let w = WizardHarness()
        await w.status(wizardStatus())
        await w.installerReady()
        await w.check([checkEnd])
        #expect(w.wizard.state(.check) == .done("Ready"))
        switch c {
        case .name: w.wizard.bottleName = "rvt2025-x"
        case .otherFolder: await w.installerReady(URL(fileURLWithPath: "/tmp/Other Installer"))
        case .failingFolder:
            await w.h.fake.set(query: ["find-installer", "/tmp/Empty", "--json"], out(#"{"year": null, "kind": null, "complete": false, "downloadable": false, "missing": [], "problem": "", "files": []}"#))
            await w.wizard.chooseInstaller(URL(fileURLWithPath: "/tmp/Empty"))
        case .source: await w.h.fake.closeGate(); Task { await w.wizard.choose(.reuseExtracted) }; try? await Task.sleep(for: .milliseconds(50))
        }
        if case .done = w.wizard.state(.check) { Issue.record("check still done after \(c)") }
        #expect(w.wizard.state(.install) == .waiting)
        await #expect(throws: (any Error).self) { try await w.wizard.install() }
        if c == .source { await w.h.fake.openGate() }
    }

    @Test func installResetsTheWizardForTheNextVersion() async throws {
        let w = WizardHarness()
        await w.status(wizardStatus())
        await w.installerReady()
        await w.check([checkEnd])
        try await w.wizard.install()
        #expect(w.wizard.installer == nil); #expect(w.wizard.bottleName == ""); #expect(w.wizard.source == nil)
        #expect(w.wizard.state(.installer) == .open); #expect(w.wizard.state(.check) == .waiting)
    }

    @Test func busyKeepsCheckAndInstallWaiting() async {
        let w = WizardHarness()
        await w.status(wizardStatus())
        await w.installerReady()
        await w.check([checkEnd])
        await w.status(wizardStatus(busy: true))
        #expect(w.wizard.state(.check) == .waiting); #expect(w.wizard.state(.install) == .waiting)
        #expect(w.wizard.busyText == "install.sh 2026 rvt2026-a")
    }
}
