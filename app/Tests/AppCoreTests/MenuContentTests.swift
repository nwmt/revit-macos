// What the menu shows: the bottles, the one line of activity, whether changing items are on; the report's arguments
// and the app's paths and links.
import Foundation
import Testing
@testable import AppCore

func run(_ request: RunRequest?, phase: RunPhase = .running, events: [EngineEvent], ctx: String = "/d/logs/runs/app-1") -> WatchedRun {
    let rec = request.map { RunRecord(ctx: ctx, runID: "app-1", request: $0, pid: 4242, pidStart: "x") }
    return WatchedRun(ctx: URL(fileURLWithPath: ctx), state: RunState.replay(events), phase: phase, record: rec)
}
let startInstall = EngineEvent.start(runID: "app-1", command: "install", year: 2025, bottle: "rvt2025-a", pid: 4242)
func freeStatus() throws -> EngineStatus { try EngineStatus.decode(statusOut().stdout) }

@Test func bottlesTitleAndRunningDot() throws {
    let m = MenuContent.make(status: try EngineStatus.decode(try Data(contentsOf: fixture("json/status-app.json"))), watched: nil, failure: nil, busy: false)
    #expect(m.bottles == [BottleItem(title: "Revit 2025 · rvt2025-a", year: 2025, bottle: "rvt2025-a", running: false)])
}

@Test func activityWhileDownloading() throws {
    let w = run(install, events: [startInstall, .action(id: "revit", state: "running", exit: nil),
                                  .progress(step: "download", done: 5_368_709_120, total: 10_737_418_240)])
    let m = MenuContent.make(status: try freeStatus(), watched: w, failure: nil, busy: true)
    #expect(m.activity == Activity(title: "Installing Revit 2025 — Downloading 50%", cancellable: true, isFailure: false))
    #expect(!m.changesEnabled)
}

@Test func activityInStepsNamesTheStep() throws {
    let w = run(install, events: [startInstall, .action(id: "steps", state: "running", exit: nil), .step(id: "rvt", state: "running", detail: nil)])
    #expect(MenuContent.make(status: try freeStatus(), watched: w, failure: nil, busy: true).activity?.title == "Installing Revit 2025 — Installing (rvt)")
}

@Test func anUnknownActionShowsItsId() throws {
    let w = run(install, events: [startInstall, .action(id: "frobnicate", state: "running", exit: nil)])
    #expect(MenuContent.make(status: try freeStatus(), watched: w, failure: nil, busy: true).activity?.title == "Installing Revit 2025 — frobnicate")
}

@Test func busyWithoutEvents() throws {
    let s = try EngineStatus.decode(statusOut(busy: true, command: "install.sh 2025 rvt2025-a").stdout)
    let m = MenuContent.make(status: s, watched: nil, failure: nil, busy: true)
    #expect(m.activity == Activity(title: "Busy: install.sh 2025 rvt2025-a", cancellable: false, isFailure: false)); #expect(!m.changesEnabled)
}

@Test func aRemoveRunIsNotCancellable() throws {
    let w = run(.remove(year: 2025, bottle: "rvt2025-a"), events: [.start(runID: "app-1", command: "remove", year: 2025, bottle: "rvt2025-a", pid: 1)])
    let a = MenuContent.make(status: try freeStatus(), watched: w, failure: nil, busy: true).activity
    #expect(a?.title == "Removing Revit 2025"); #expect(a?.cancellable == false)
}

@Test func aRunStartedElsewhereIsNotCancellable() throws {
    let w = run(nil, events: [startInstall, .action(id: "unpack", state: "running", exit: nil)])
    let a = MenuContent.make(status: try freeStatus(), watched: w, failure: nil, busy: true).activity
    #expect(a?.title == "Installing Revit 2025 — Unpacking"); #expect(a?.cancellable == false)
}

@Test func finishingReadsFinishingNotCancellable() throws {
    let w = run(install, phase: .finishing, events: [startInstall, .action(id: "steps", state: "running", exit: nil)])
    #expect(MenuContent.make(status: try freeStatus(), watched: w, failure: nil, busy: true).activity
            == Activity(title: "Installing Revit 2025 — finishing…", cancellable: false, isFailure: false))
}

@Test func aPartialInstallReadsFinishedWithProblems() throws {
    let w = run(install, phase: .ended, events: [startInstall, .end(EndInfo(exitCode: 1, result: "partial", failedAction: "", failedSteps: ["dynamo"], logDir: "/l", reason: nil))])
    let m = MenuContent.make(status: try freeStatus(), watched: w, failure: .partial(steps: ["dynamo"], logDir: "/l", downloadFailed: false), busy: false)
    #expect(m.activity == Activity(title: "Revit 2025: install finished with problems — details", cancellable: false, isFailure: true))
    #expect(m.changesEnabled)
}

@Test func aFailureAndAnInterruptionRead() throws {
    let w = run(install, phase: .ended, events: [startInstall])
    #expect(MenuContent.make(status: try freeStatus(), watched: w, failure: .noSpace(logDir: "/l"), busy: false).activity?.title
            == "Revit 2025: install failed — details")
    let i = run(install, phase: .interrupted, events: [startInstall])
    #expect(MenuContent.make(status: try freeStatus(), watched: i, failure: .interrupted(logDir: ""), busy: false).activity?.title
            == "Revit 2025: install was interrupted — details")
}

@Test func idleNoActivityChangesEnabled() throws {
    let m = MenuContent.make(status: try freeStatus(), watched: nil, failure: nil, busy: false)
    #expect(m.activity == nil); #expect(m.changesEnabled)
    let ok = run(install, phase: .ended, events: [startInstall, .end(EndInfo(exitCode: 0, result: "ok", failedAction: "", failedSteps: [], logDir: "", reason: nil))])
    #expect(MenuContent.make(status: try freeStatus(), watched: ok, failure: nil, busy: false).activity == nil)
}

@Test func reportArgs() throws {
    #expect(ReportAction.make(year: 2025, bottle: "rvt2025-a", logDir: "/l") == ["report", "2025", "rvt2025-a", "--json", "--run", "/l"])
    #expect(ReportAction.make(year: 2025, bottle: "rvt2025-a", logDir: nil) == ["report", "2025", "rvt2025-a", "--json"])
    #expect(ReportAction.make(year: nil, bottle: nil, logDir: nil) == ["report", "--json"])
}

@Test func aRefusalOnStdoutWithExit1Decodes() throws {
    let out = EngineOutput(stdout: Data(#"{"report_txt": null, "report_zip": null, "left_out": [], "summary": null, "refused": "report.txt holds personal data that could not be removed", "hits": []}"#.utf8), stderr: "", exitCode: 1)
    #expect(ReportAction.result(out)?.refused == "report.txt holds personal data that could not be removed")
    #expect(ReportAction.result(EngineOutput(stdout: Data("oops".utf8), stderr: "x", exitCode: 1)) == nil)
}

@Test func appLinksPaths() {
    let home = URL(fileURLWithPath: "/tmp/h")
    #expect(AppLinks.revitApp(year: 2025, bottle: "rvt2025-a", home: home).path == "/tmp/h/Applications/Revit 2025 (rvt2025-a).app")
    #expect(AppLinks.viewerApp(year: 2025, bottle: "rvt2025-a", home: home).path == "/tmp/h/Applications/Revit Viewer 2025 (rvt2025-a).app")
    #expect(AppLinks.logs(data: URL(fileURLWithPath: "/tmp/d"), bottle: nil).path == "/tmp/d/logs")
    #expect(AppLinks.logs(data: URL(fileURLWithPath: "/tmp/d"), bottle: "rvt2025-a").path == "/tmp/d/logs/rvt2025-a")
    #expect(AppLinks.readme(repo: "nwmt/revit-macos").absoluteString == "https://github.com/nwmt/revit-macos#readme")
    #expect(AppLinks.releases(repo: "nwmt/revit-macos").absoluteString == "https://github.com/nwmt/revit-macos/releases")
}
