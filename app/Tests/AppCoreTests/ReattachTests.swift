// "The app quit during an install and was opened again", with real processes: SpawnProbe starts the fake engine as
// the app would and exits; a new AppModel on the same defaults finds the run, knows it as its own and cancels it.
import Darwin
import Foundation
import Testing
@testable import AppCore

@MainActor @Suite(.serialized) struct ReattachTests {

    /// Starts install 2025 rvt2025-a --yes through SpawnProbe; returns the record the app would have saved.
    func probeStart(root: URL, fakeDir: URL, extra: [String: String] = [:]) throws -> RunRecord {
        let probe = try #require(ProcessInfo.processInfo.environment["SPAWN_PROBE"], "run app/test.sh: it builds SpawnProbe")
        let ctx = root.appending(path: "data/logs/runs/app-20261017-101500-ab12")
        try FileManager.default.createDirectory(at: ctx, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: probe)
        p.arguments = [fakeEngine.path, ctx.path, "install", "2025", "rvt2025-a", "--yes"]
        p.environment = TestEnv.make(root: root, fake: ["FAKE_SCENARIO": "slow", "FAKE_DIR": fakeDir.path].merging(extra) { _, n in n })
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let line = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let pid = try #require(Int32(parts.first ?? ""))
        return RunRecord(ctx: ctx.path, runID: ctx.lastPathComponent, request: .install(year: 2025, bottle: "rvt2025-a", source: nil),
                         pid: pid, pidStart: parts.count > 1 ? parts[1] : "")
    }

    func cameBack(extra: [String: String] = [:], early: Bool) async throws {
        let root = tempDir(), fakeDir = root.appending(path: "fake")
        try FileManager.default.createDirectory(at: fakeDir, withIntermediateDirectories: true)
        let rec = try probeStart(root: root, fakeDir: fakeDir, extra: extra)
        defer { killGroup(rec.pid) }
        let defaults = TestDefaults.make(); defer { TestDefaults.remove(defaults) }
        defaults.set(try JSONEncoder().encode(rec), forKey: "lastRun")
        if !early { #expect(await waitFor { FileManager.default.fileExists(atPath: fakeDir.appending(path: "status.json").path) }) }
        let env = TestEnv.make(root: root, fake: ["FAKE_DIR": fakeDir.path])
        let model = AppModel(engine: ProcessEngine(engine: fakeEngine, environment: env), defaults: defaults,
                             notifier: FakeNotifier(), dataOverride: root.appending(path: "data"))
        await model.launch()
        #expect(model.watched?.record == rec); #expect(model.watched?.phase == .running)
        if early {
            #expect(model.watched?.state.runID == nil)
            var started = false
            for _ in 0..<60 where !started { try await Task.sleep(for: .milliseconds(100)); await model.poll(); started = model.watched?.state.runID != nil }
            #expect(started)
            #expect(await waitFor { FileManager.default.fileExists(atPath: fakeDir.appending(path: "status.json").path) })
        }
        #expect(await model.cancel() == .sent)
        var ended = false
        for _ in 0..<50 where !ended { try await Task.sleep(for: .milliseconds(100)); await model.poll(); ended = model.watched?.phase == .ended }
        #expect(ended); #expect(model.failure == nil)
        #expect(await waitFor { pgrepGroup(rec.pid).isEmpty })
    }

    @Test func anAppThatQuitAndCameBackCancelsItsRun() async throws { try await cameBack(early: false) }

    @Test func anAppThatQuitAndCameBackBeforeItsEventsFileExists() async throws {
        try await cameBack(extra: ["FAKE_EVENTS_DELAY": "3"], early: true)
    }
}
