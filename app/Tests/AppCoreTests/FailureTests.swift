// The engine's end of a run as the failure the app shows (spec §4): one screen per kind, the engine's own text.
import Foundation
import Testing
@testable import AppCore

func end(_ result: String, action: String = "", steps: [String] = [], logDir: String = "/l", reason: String? = nil, exit: Int = 1) -> EndInfo {
    EndInfo(exitCode: exit, result: result, failedAction: action, failedSteps: steps, logDir: logDir, reason: reason)
}
func status(crossover: Bool = true, rosetta: Bool = true, owner: String = "") throws -> EngineStatus {
    try EngineStatus.decode(statusOut(busy: !owner.isEmpty, command: owner, crossover: crossover, rosetta: rosetta).stdout)
}
let err = [Message(level: "warn", text: "w"), Message(level: "error", text: "first"), Message(level: "error", text: "rvt: why it failed")]

@Test func busyNamesTheOwner() throws {
    #expect(Failure.from(end: end("busy"), messages: [], console: "", status: try status(owner: "install.sh 2025 rvt2025-a")) == .busy(owner: "install.sh 2025 rvt2025-a"))
}
@Test func sourceMismatchKeepsTheText() throws {
    #expect(Failure.from(end: end("source_mismatch"), messages: err, console: "", status: try status()) == .sourceMismatch(text: "rvt: why it failed"))
}
@Test func inUseKeepsTheText() throws {
    #expect(Failure.from(end: end("in_use"), messages: err, console: "", status: try status()) == .inUse(text: "rvt: why it failed"))
}
@Test func noSpace() throws {
    #expect(Failure.from(end: end("failed", action: "revit", reason: "no_space"), messages: [], console: "", status: try status()) == .noSpace(logDir: "/l"))
}
@Test func failedDownloadIsBroken() throws {
    #expect(Failure.from(end: end("failed", action: "revit", reason: "download"), messages: [], console: "", status: try status()) == .downloadBroken(logDir: "/l"))
}
@Test func partialWithADownloadStaysPartial() throws {
    #expect(Failure.from(end: end("partial", steps: ["dynamo", "pyrevit"], reason: "download"), messages: [], console: "", status: try status())
            == .partial(steps: ["dynamo", "pyrevit"], logDir: "/l", downloadFailed: true))
    #expect(Failure.from(end: end("partial", steps: ["dynamo"]), messages: [], console: "", status: try status())
            == .partial(steps: ["dynamo"], logDir: "/l", downloadFailed: false))
}
@Test func noCrossOver() throws {
    #expect(Failure.from(end: end("failed"), messages: err, console: "", status: try status(crossover: false)) == .crossoverMissing)
}
@Test func noRosetta() throws {
    #expect(Failure.from(end: end("failed"), messages: err, console: "", status: try status(rosetta: false)) == .rosettaMissing)
}
@Test func usage() throws {
    #expect(Failure.from(end: end("usage"), messages: [], console: "x\nRevit 2021 is not supported yet.\n", status: try status())
            == .usage(text: "x\nRevit 2021 is not supported yet."))
}
@Test func unknownResultIsFailed() throws {
    #expect(Failure.from(end: end("weird", action: "unpack"), messages: err, console: "", status: try status()) == .failed(at: "unpack", text: "rvt: why it failed", logDir: "/l"))
}
@Test func textFromTheConsoleTailWithoutAnErrorMessage() throws {
    #expect(Failure.from(end: end("failed", action: "bottle"), messages: [Message(level: "warn", text: "w")], console: "a\nb\n\nc\nd\n\n", status: try status())
            == .failed(at: "bottle", text: "b\nc\nd", logDir: "/l"))
}
@Test func noFailedActionMeansTheLastFailedStep() throws {
    #expect(Failure.from(end: end("failed", steps: ["netfx", "rvt"]), messages: err, console: "", status: try status()) == .failed(at: "rvt", text: "rvt: why it failed", logDir: "/l"))
    #expect(Failure.from(end: end("failed"), messages: err, console: "", status: nil) == .failed(at: "", text: "rvt: why it failed", logDir: "/l"))
}
@Test func okAndStoppedAreNoFailure() throws {
    #expect(Failure.from(end: end("ok", exit: 0), messages: err, console: "", status: try status()) == nil)
    #expect(Failure.from(end: end("stopped", exit: 130), messages: [], console: "", status: try status(crossover: false)) == nil)
}
