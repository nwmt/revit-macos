// The run state built from the events: what the menu and the progress window show.
import Foundation
import Testing
@testable import AppCore

@Test func installOkReplays() throws {
    var r = NDJSONReader(url: fixture("events/install-ok.ndjson"))
    let s = RunState.replay(try r.readNew())
    #expect(s.runID == "app-20261017-101500-ab12"); #expect(s.command == "install"); #expect(s.year == 2025)
    #expect(s.bottle == "rvt2025-a"); #expect(s.pid == 4242)
    #expect(s.actions.map(\.id) == ["shims", "revit", "steps"]); #expect(s.actions.allSatisfy { $0.state == "done" })
    #expect(s.steps == [Item(id: "rvt", state: "done", detail: "Revit 2025.4 (412 s)")])
    #expect(s.messages.map(\.level) == ["warn"]); #expect(s.end?.kind == .ok)
    #expect(s.download == DownloadProgress(done: 5_368_709_120, total: 10_737_418_240))
}

@Test func installPartialReplays() throws {
    var r = NDJSONReader(url: fixture("events/install-partial.ndjson"))
    let s = RunState.replay(try r.readNew())
    #expect(s.end?.kind == .partial); #expect(s.end?.failedSteps == ["dynamo"]); #expect(s.end?.exitCode == 1)
    #expect(s.steps == [Item(id: "dynamo", state: "failed", detail: "see ~/x/dynamo.log")])
}

@Test func noSpaceCarriesItsReason() throws {
    var r = NDJSONReader(url: fixture("events/no-space.ndjson"))
    let s = RunState.replay(try r.readNew())
    #expect(s.end?.kind == .failed); #expect(s.end?.failedAction == "revit"); #expect(s.end?.reason == "no_space")
}

@Test func sourceMismatchReplays() throws {
    var r = NDJSONReader(url: fixture("events/source-mismatch.ndjson"))
    let s = RunState.replay(try r.readNew())
    #expect(s.command == "check"); #expect(s.end?.kind == .sourceMismatch)
    #expect(s.messages == [Message(level: "error", text: "installers/extracted/revit2025 was unpacked from another installer")])
}

@Test func currentActivityAndPercent() {
    var s = RunState()
    s.apply(.action(id: "revit", state: "running", exit: nil))
    s.apply(.progress(step: "download", done: 5_368_709_120, total: 10_737_418_240))
    #expect(s.currentAction == "revit"); #expect(s.downloadPercent == 50)
    s.apply(.progress(step: "download", done: 20, total: 10)); #expect(s.downloadPercent == 100)
    s.apply(.progress(step: "download", done: 3, total: 0)); #expect(s.downloadPercent == nil)
    s.apply(.action(id: "steps", state: "running", exit: nil)); s.apply(.step(id: "rvt", state: "running", detail: nil))
    #expect(s.currentStep == "rvt"); #expect(s.currentAction == "steps")
    s.apply(.step(id: "rvt", state: "done", detail: nil)); #expect(s.currentStep == nil)
}

@Test func nothingChangesAfterEnd() {
    var s = RunState()
    s.apply(.step(id: "a", state: "done", detail: nil))
    s.apply(.end(EndInfo(exitCode: 0, result: "ok", failedAction: "", failedSteps: [], logDir: "", reason: nil)))
    let before = s
    s.apply(.step(id: "b", state: "running", detail: nil))
    s.apply(.message(level: "warn", text: "late"))
    #expect(s == before)
}

@Test func noEndReplayIsUnfinished() throws {
    var r = NDJSONReader(url: fixture("events/no-end.ndjson"))
    let s = RunState.replay(try r.readNew())
    #expect(s.end == nil); #expect(s.currentAction == "unpack")
}

@Test func unknownEventsChangeNothing() {
    var s = RunState(); s.apply(.action(id: "a", state: "running", exit: nil))
    let before = s
    s.apply(.unknown("plan"))
    #expect(s == before)
}
