// The models of the engine's JSON answers (status, find-installer, addins list, report, the dry-run plans).
import Foundation
import Testing
@testable import AppCore

func data(_ s: String) -> Data { Data(s.utf8) }

@Test func statusOfTheAppDecodes() throws {
    let s = try EngineStatus.decode(try Data(contentsOf: fixture("json/status-app.json")))
    #expect(s.crossover == CrossOver(found: true, path: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver", version: "26.3.0", supported: true))
    #expect(s.rosetta); #expect(s.msls31)
    #expect(s.busy.busy); #expect(s.busy.pidNumber == 4242); #expect(s.busy.pgidNumber == 4242); #expect(s.busy.runId == "app-20261017-101500-ab12")
    #expect(s.busy.pidStart == "Sat Oct 17 10:15:00 2026"); #expect(s.busy.ctx == "/tmp/data/logs/runs/app-20261017-101500-ab12")
    #expect(s.bottles.count == 1); #expect(s.bottles[0].yearNumber == 2025); #expect(s.bottles[0].addins == ["pyrevit"])
    #expect(s.app?.placement == "move"); #expect(s.app?.data == "/tmp/home/Library/Application Support/Test App")
}

@Test func statusOfACloneHasNoApp() throws {
    let s = try EngineStatus.decode(try Data(contentsOf: fixture("json/status-clone.json")))
    #expect(s.app == nil); #expect(s.bottles.isEmpty); #expect(!s.crossover.found); #expect(!s.busy.busy)
}

@Test func emptyOwnerFieldsAreNilNumbers() throws {
    let s = try EngineStatus.decode(try Data(contentsOf: fixture("json/status-clone.json")))
    #expect(s.busy.pidNumber == nil); #expect(s.busy.pgidNumber == nil)
    #expect(Bottle(name: "x", year: "", revit: false, running: false, addins: []).yearNumber == nil)
}

@Test func extraKeysAreIgnored() throws {
    let s = try EngineStatus.decode(data(#"{"future":1,"crossover":{"found":true,"path":"/x","version":"26.3.0","supported":true,"future":1},"rosetta":true,"msls31":false,"busy":{"busy":false,"command":"","run_id":"","pid":"","pid_start":"","pgid":"","ctx":""},"bottles":[{"name":"b","year":"2024","revit":false,"running":false,"addins":[],"future":1}]}"#))
    #expect(s.bottles.map(\.name) == ["b"])
}

@Test func installerInfoDecodes() throws {
    let i = try JSONDecoder.engine.decode(InstallerInfo.self, from: data(#"{"year": "2025", "kind": "create-installer", "complete": false, "downloadable": true, "missing": ["RVT_2025_B_002_002.7z"], "problem": "", "files": [{"name": "Create_Installer_RVT_2025_5_English_WIN64.exe", "check": "unknown"}]}"#))
    #expect(i.year == "2025"); #expect(i.kind == "create-installer"); #expect(i.downloadable); #expect(i.missing == ["RVT_2025_B_002_002.7z"])
    #expect(i.files == [InstallerFile(name: "Create_Installer_RVT_2025_5_English_WIN64.exe", check: "unknown")])
    let none = try JSONDecoder.engine.decode(InstallerInfo.self, from: data(#"{"year": null, "kind": null, "complete": false, "downloadable": false, "missing": [], "problem": "", "files": []}"#))
    #expect(none.year == nil); #expect(none.kind == nil)
}

@Test func addinListDecodes() throws {
    let a = try JSONDecoder.engine.decode([AddinInfo].self, from: data(#"[{"id":"pyrevit","name":"pyRevit","about":"Scripts","available":true,"installed":false,"tested":true,"source":"auto","eula":"","tool":"","tool_ok":true,"ready":true}]"#))
    #expect(a == [AddinInfo(id: "pyrevit", name: "pyRevit", about: "Scripts", available: true, installed: false, tested: true, source: "auto", eula: "", tool: "", toolOk: true, ready: true)])
}

@Test func reportRefusedDecodes() throws {
    let r = try JSONDecoder.engine.decode(ReportResult.self, from: data(#"{"report_txt": null, "report_zip": null, "left_out": [], "summary": null, "refused": "the finished report did not pass the check", "hits": []}"#))
    #expect(r.refused == "the finished report did not pass the check"); #expect(r.reportTxt == nil); #expect(r.reportZip == nil)
    let ok = try JSONDecoder.engine.decode(ReportResult.self, from: data(#"{"report_txt": "/l/report.txt", "report_zip": "/l/report.zip", "left_out": [], "summary": "3 removed", "refused": null, "hits": []}"#))
    #expect(ok.reportTxt == "/l/report.txt"); #expect(ok.summary == "3 removed"); #expect(ok.refused == nil)
}

@Test func removePlanDecodes() throws {
    let r = try JSONDecoder.engine.decode(RemovePlan.self, from: data(#"{"command":"remove","year":2025,"bottle":"rvt2025-a","nothing":false,"delete":[{"label":"bottle rvt2025-a","bytes":123456},{"label":"~/Applications/Revit 2025 (rvt2025-a).app","bytes":null}],"kept":["installers/revit2025 (your downloads)"],"notes":["Documents in this bottle is your Mac folder ~/Documents. It stays.","Everything else on the bottle's C: drive is deleted."]}"#))
    #expect(r.nothing == false); #expect(r.delete == [PlanItem(label: "bottle rvt2025-a", bytes: 123456), PlanItem(label: "~/Applications/Revit 2025 (rvt2025-a).app", bytes: nil)])
    #expect(r.kept == ["installers/revit2025 (your downloads)"]); #expect(r.addinsReset == nil); #expect(r.notes.count == 2)
    let b = try JSONDecoder.engine.decode(RemovePlan.self, from: data(#"{"command":"rebuild","year":2025,"bottle":"rvt2025-a","delete":[{"label":"bottle rvt2025-a","bytes":1024}],"addins_reset":true,"notes":["a","b"]}"#))
    #expect(b.command == "rebuild"); #expect(b.addinsReset == true); #expect(b.nothing == nil); #expect(b.kept == nil)
}
