// The engine's events (--events): parsing each line, and reading a file that the engine is still writing.
import Foundation
import Testing
@testable import AppCore

@Test func parsesEveryEventKind() {
    #expect(EventParser.parse(#"{"event":"start","run_id":"r","command":"status","year":null,"bottle":null,"pid":1}"#)
            == .start(runID: "r", command: "status", year: nil, bottle: nil, pid: 1))
    #expect(EventParser.parse(#"{"event":"action","id":"unpack","state":"done","exit":0}"#) == .action(id: "unpack", state: "done", exit: 0))
    #expect(EventParser.parse(#"{"event":"step","id":"rvt","state":"done","detail":"Revit 2025.4 (412 s)"}"#)
            == .step(id: "rvt", state: "done", detail: "Revit 2025.4 (412 s)"))
    #expect(EventParser.parse(#"{"event":"progress","step":"download","done":5368709120,"total":10737418240}"#)
            == .progress(step: "download", done: 5_368_709_120, total: 10_737_418_240))
    #expect(EventParser.parse(#"{"event":"message","level":"warn","text":"a\nb"}"#) == .message(level: "warn", text: "a\nb"))
    #expect(EventParser.parse(#"{"event":"end","exit_code":1,"result":"partial","failed_action":"","failed_steps":["dynamo"],"log_dir":"/l","reason":"download"}"#)
            == .end(EndInfo(exitCode: 1, result: "partial", failedAction: "", failedSteps: ["dynamo"], logDir: "/l", reason: "download")))
    #expect(EventParser.parse(#"{"event":"end","exit_code":0,"result":"ok","failed_action":"","failed_steps":[],"log_dir":""}"#)
            == .end(EndInfo(exitCode: 0, result: "ok", failedAction: "", failedSteps: [], logDir: "", reason: nil)))
}

@Test func unknownEventIsUnknown() { #expect(EventParser.parse(#"{"event":"plan","n":3}"#) == .unknown("plan")) }

@Test(arguments: ["not json", "", #"{"event":"step"}"#, #"{"x":1}"#, #"["event"]"#, #"{"event":"end","result":"ok"}"#])
func malformedLineIsNil(_ line: String) { #expect(EventParser.parse(line) == nil) }

@Test func resultKinds() {
    #expect(RunResult("ok") == .ok); #expect(RunResult("partial") == .partial); #expect(RunResult("stopped") == .stopped)
    #expect(RunResult("source_mismatch") == .sourceMismatch); #expect(RunResult("in_use") == .inUse)
    #expect(RunResult("weird") == .other("weird"))
}

@Test func tornLastLineWaitsForItsEnd() throws {
    let f = tempDir().appending(path: "events.ndjson")
    append(f, "{\"event\":\"start\",\"run_id\":\"r\",\"command\":\"install\",\"year\":2025,\"bottle\":\"b\",\"pid\":1}\n{\"event\":\"action\",\"id\":\"un")
    var r = NDJSONReader(url: f)
    #expect(try r.readNew().count == 1)
    append(f, "pack\",\"state\":\"running\"}\n")
    #expect(try r.readNew() == [.action(id: "unpack", state: "running", exit: nil)])
    #expect(try r.readNew().isEmpty)
}

@Test func missingFileIsNoEventsYet() throws {
    var r = NDJSONReader(url: tempDir().appending(path: "none"))
    #expect(try r.readNew().isEmpty)
}

@Test func badLinesAreSkippedAndCounted() throws {
    var r = NDJSONReader(url: fixture("events/unknown-and-bad.ndjson"))
    let e = try r.readNew()
    #expect(e.count == 3)        // start, unknown, end
    #expect(r.malformed == 2)
}

@Test func invalidUTF8IsSkipped() throws {
    let f = tempDir().appending(path: "events.ndjson")
    append(f, Data([0xff, 0xfe, 0x0a]))
    append(f, "{\"event\":\"end\",\"exit_code\":0,\"result\":\"ok\",\"failed_action\":\"\",\"failed_steps\":[],\"log_dir\":\"\"}\n")
    var r = NDJSONReader(url: f)
    #expect(try r.readNew().count == 1)
    #expect(r.malformed == 1)
}
