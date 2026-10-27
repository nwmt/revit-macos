// The trackpad helper's state file and arguments (TrackpadState): the format the app and the helper share.
import Foundation
import Testing
import TrackpadState

@Test func stateRoundTrip() throws {
    let d = tempDir(), f = d.appending(path: "trackpad/state.json")
    let s = HelperState(session: "s1", pid: 42, start: "Mon_Oct_26_10:00:00_2026", trusted: true, posting: true, tap: true,
                        error: nil, restart: nil, bottles: ["rvt2027-a": BottleState(ready: true, error: nil)])
    try StateFile.write(s, to: f)
    #expect(StateFile.read(f) == s)
    let names = try FileManager.default.contentsOfDirectory(atPath: f.deletingLastPathComponent().path)
    #expect(names == ["state.json"])   // no temporary file left
}

@Test func damagedOrMissingStateIsNil() throws {
    let d = tempDir(), f = d.appending(path: "state.json")
    #expect(StateFile.read(f) == nil)
    try Data("{\"session\":".utf8).write(to: f)
    #expect(StateFile.read(f) == nil)
}

@Test func argsRoundTrip() {
    let a = HelperArgs(session: "s1", parentPid: 42, parentStart: "Mon_Oct_26_10:00:00_2026",
                       engine: URL(fileURLWithPath: "/Applications/X.app/Contents/Resources/engine/revit"),
                       data: URL(fileURLWithPath: "/tmp/home/Library/Application Support/X"), recover: true, recoverOnly: false)
    #expect(HelperArgs.parse(a.argv()) == a)
    let b = HelperArgs(session: "s2", parentPid: 1, parentStart: "x", engine: URL(fileURLWithPath: "/e"),
                       data: URL(fileURLWithPath: "/d"), recover: false, recoverOnly: true)
    #expect(HelperArgs.parse(b.argv()) == b)
}

@Test func argsNeedASession() {
    #expect(HelperArgs.parse(["--parent", "42:x", "--engine", "/e", "--data", "/d"]) == nil)
    #expect(HelperArgs.parse(["--session", "s", "--parent", "bad", "--engine", "/e", "--data", "/d"]) == nil)
    #expect(HelperArgs.parse(["--session", "s", "--parent", "42:x", "--engine", "/e", "--data", "/d", "--what"]) == nil)
}
