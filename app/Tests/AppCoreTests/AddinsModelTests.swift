// The add-ins window of one bottle: the catalog's rows for its year, what is installed in that bottle, own files,
// EULA consent, the Ghostscript tool, and the run that installs the selected ones.
import Foundation
import Testing
@testable import AppCore

func bottleStatus(_ name: String, year: Int, addins: [String]) -> EngineOutput {
    let a = addins.map { "\"\($0)\"" }.joined(separator: ",")
    let json = #"{"crossover":{"found":true,"path":"/x","version":"26.3.0","supported":true},"rosetta":true,"msls31":true,"busy":{"busy":false,"command":"","run_id":"","pid":"","pid_start":"","pgid":"","ctx":""},"bottles":[{"name":"\#(name)","year":"\#(year)","revit":true,"running":false,"addins":[\#(a)]}]}"#
    return EngineOutput(stdout: Data(json.utf8), stderr: "", exitCode: 0)
}
let enscape2027 = #"[{"id":"enscape","name":"Enscape","about":"Real-time rendering","available":true,"installed":false,"tested":true,"source":"own","eula":"https://www.chaos.com/eula","tool":"","tool_ok":true,"ready":READY}]"#
let mcpNotice = "Autodesk's MCP Server is a Technical Preview and runs only with Autodesk analytics (ADP); installing it turns ADP on in this bottle."
let mcp2027 = #"[{"id":"revitmcp-experimental","name":"Revit MCP Server (Experimental-Tools)","about":"AI","available":true,"installed":false,"tested":false,"source":"own","eula":"https://www.autodesk.com/company/terms-of-use/en/general-terms","notice":"\#(mcpNotice)","tool":"","tool_ok":true,"ready":true},{"id":"revitmcp","name":"Revit MCP Server (Write-Tools)","about":"AI","available":true,"installed":false,"tested":false,"source":"own","eula":"https://www.autodesk.com/company/terms-of-use/en/general-terms","notice":"\#(mcpNotice)","tool":"","tool_ok":true,"ready":true}]"#

@MainActor final class AddinsHarness {
    let h = Harness()
    let system = FakeSystem()
    let model: AddinsModel
    init(year: Int, bottle: String, list: String, addins: [String] = []) async {
        await h.fake.set(query: ["addins", "list", String(year), "--json"], EngineOutput(stdout: Data(list.utf8), stderr: "", exitCode: 0))
        await h.fake.setStatus([bottleStatus(bottle, year: year, addins: addins)])
        model = AddinsModel(app: h.model, system: system, year: year, bottle: bottle)
        await model.load()
    }
}

@MainActor @Suite(.serialized) struct AddinsModelTests {
    static let list2025 = text(fixture("json/addins-2025.json"))

    @Test func rowsFromCatalogAndStatus() async {
        let a = await AddinsHarness(year: 2025, bottle: "rvt2025-b", list: Self.list2025, addins: ["revitlookup"])
        a.system.brewPath = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        await a.model.load()
        #expect(a.model.rows.map(\.id) == ["pdfprinter", "pyrevit", "revitlookup"])
        #expect(a.model.rows.map(\.state) == [.needsTool(brew: true), .available, .installed])
        #expect(a.model.rows.allSatisfy { $0.tested })
    }

    @Test func installedComesFromTheBottleNotTheList() async {
        let a = await AddinsHarness(year: 2025, bottle: "rvt2025-b", list: Self.list2025, addins: [])
        #expect(a.model.rows.first { $0.id == "revitlookup" }?.state == .available)
        #expect(a.model.rows.first { $0.id == "pdfprinter" }?.state == .needsTool(brew: false))
    }

    @Test func anOwnAddinNeedsItsFileThenIsAvailable() async {
        let a = await AddinsHarness(year: 2027, bottle: "rvt2027-a", list: enscape2027.replacingOccurrences(of: "READY", with: "false"))
        #expect(a.model.rows.map(\.state) == [.needsFile])
        let f = URL(fileURLWithPath: "/tmp/x/Enscape-4.18.2.1657-lts.exe")
        await a.h.fake.set(query: ["addins", "import", "enscape", f.path], EngineOutput(stdout: Data("Enscape: Enscape-4.18.2.1657-lts.exe is ready.\n".utf8), stderr: "", exitCode: 0))
        await a.h.fake.set(query: ["addins", "list", "2027", "--json"], EngineOutput(stdout: Data(enscape2027.replacingOccurrences(of: "READY", with: "true").utf8), stderr: "", exitCode: 0))
        await a.model.importFile("enscape", f)
        #expect(await a.h.fake.calls.contains("run addins import enscape /tmp/x/Enscape-4.18.2.1657-lts.exe"))
        #expect(a.model.rows.map(\.state) == [.available]); #expect(a.model.error == nil)
    }

    @Test func aRefusedImportShowsItsText() async {
        let a = await AddinsHarness(year: 2027, bottle: "rvt2027-a", list: enscape2027.replacingOccurrences(of: "READY", with: "false"))
        let f = URL(fileURLWithPath: "/tmp/x/other.exe")
        await a.h.fake.set(query: ["addins", "import", "enscape", f.path], EngineOutput(stdout: Data(), stderr: "Enscape: this file is not one the add-in setup knows. Expected one of: Enscape-4.18.2.1657-lts.exe\n", exitCode: 1))
        await a.model.importFile("enscape", f)
        #expect(a.model.error == "Enscape: this file is not one the add-in setup knows. Expected one of: Enscape-4.18.2.1657-lts.exe")
    }

    @Test func eulaToggleReturnsTheURLAndSelectsNothingAcceptSelects() async {
        let a = await AddinsHarness(year: 2027, bottle: "rvt2027-a", list: enscape2027.replacingOccurrences(of: "READY", with: "true"))
        #expect(a.model.toggle("enscape") == "https://www.chaos.com/eula"); #expect(a.model.selected.isEmpty)
        a.model.accept("enscape")
        #expect(a.model.selected == ["enscape"]); #expect(a.model.accepted == ["enscape"])
        #expect(a.model.toggle("enscape") == nil); #expect(a.model.selected.isEmpty)
    }

    @Test func mcpNoticeReachesTheRowsAndEachVariantNeedsItsOwnConsent() async throws {
        let a = await AddinsHarness(year: 2027, bottle: "rvt2027-a", list: mcp2027)
        #expect(a.model.rows.map(\.notice) == [mcpNotice, mcpNotice])
        #expect(a.model.toggle("revitmcp") == "https://www.autodesk.com/company/terms-of-use/en/general-terms")
        #expect(a.model.selected.isEmpty)
        a.model.accept("revitmcp")
        #expect(a.model.toggle("revitmcp-experimental") == "https://www.autodesk.com/company/terms-of-use/en/general-terms")
        #expect(a.model.selected == ["revitmcp"]); #expect(a.model.accepted == ["revitmcp"])
        try await a.model.installSelected()
        #expect(await a.h.fake.started.last == ["addins", "2027", "rvt2027-a", "--only", "revitmcp", "--accept-eula", "revitmcp"])
        let b = await AddinsHarness(year: 2027, bottle: "rvt2027-a", list: mcp2027)
        b.model.accept("revitmcp-experimental")
        try await b.model.installSelected()
        #expect(await b.h.fake.started.last == ["addins", "2027", "rvt2027-a", "--only", "revitmcp-experimental", "--accept-eula", "revitmcp-experimental"])
        #expect(b.model.rows.first { $0.id == "enscape" } == nil)
    }

    @Test func installSelectedPassesIdsInCatalogOrderAndTheAcceptedEULAs() async throws {
        let a = await AddinsHarness(year: 2027, bottle: "rvt2027-a", list: enscape2027.replacingOccurrences(of: "READY", with: "true"))
        a.model.accept("enscape")
        try await a.model.installSelected()
        #expect(await a.h.fake.started.last == ["addins", "2027", "rvt2027-a", "--only", "enscape", "--accept-eula", "enscape"])
        let b = await AddinsHarness(year: 2025, bottle: "rvt2025-a", list: Self.list2025)
        #expect(b.model.toggle("revitlookup") == nil); #expect(b.model.toggle("pyrevit") == nil)
        try await b.model.installSelected()
        #expect(await b.h.fake.started.last == ["addins", "2025", "rvt2025-a", "--only", "pyrevit,revitlookup"])
    }

    @Test func installedRowsCannotBeToggled() async {
        let a = await AddinsHarness(year: 2025, bottle: "rvt2025-b", list: Self.list2025, addins: ["revitlookup"])
        _ = a.model.toggle("revitlookup"); _ = a.model.toggle("pdfprinter")
        #expect(a.model.selected.isEmpty)
    }

    @Test func nothingSelectedNoRun() async throws {
        let a = await AddinsHarness(year: 2025, bottle: "rvt2025-a", list: Self.list2025)
        try await a.model.installSelected()
        #expect(await a.h.fake.started.isEmpty)
    }

    @Test func installToolRunsBrewInstallGhostscript() async {
        let a = await AddinsHarness(year: 2025, bottle: "rvt2025-a", list: Self.list2025)
        a.system.brewPath = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        await a.model.installTool("pdfprinter")
        #expect(a.system.brewArgs == [["install", "ghostscript"]])
    }
}
