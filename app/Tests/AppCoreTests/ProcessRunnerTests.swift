// The runner of the wizard's Mac programs (osascript, brew) and the link a notification carries.
import Foundation
import Testing
@testable import AppCore

@Test func aLogThatCannotBeOpenedFailsBeforeAnythingRuns() async throws {
    let d = tempDir().appending(path: "ro"); try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: d.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d.path) }
    let mark = tempDir().appending(path: "ran")
    await #expect(throws: (any Error).self) {
        _ = try await ProcessRunner.run("/bin/sh", ["-c", "touch '\(mark.path)'"], env: [:], log: d.appending(path: "brew.log"))
    }
    #expect(!FileManager.default.fileExists(atPath: mark.path))
}

@Test func largeOutputDoesNotBlockTheRunner() async throws {
    let script = "i=0; while [ $i -lt 4000 ]; do echo 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' >&2; i=$((i+1)); done; exit 3"
    let noLog = try await ProcessRunner.run("/bin/sh", ["-c", script], env: [:], log: nil)
    #expect(noLog.status == 3); #expect(noLog.stderr.count > 300_000)
    let log = tempDir().appending(path: "brew.log")
    let logged = try await ProcessRunner.run("/bin/sh", ["-c", script], env: [:], log: log)
    #expect(logged.status == 3); #expect(text(log).count > 300_000)
}

@Test func aNotificationKeepsItsLink() {
    let u = URL(string: "https://github.com/o/r/releases/tag/app-v0.1.1")!
    #expect(NotificationLink.url(from: NotificationLink.userInfo(u)) == u)
    #expect(NotificationLink.url(from: NotificationLink.userInfo(nil)) == nil)
    #expect(NotificationLink.isRelease(NotificationLink.userInfo(u, release: true)))
    #expect(!NotificationLink.isRelease(NotificationLink.userInfo(URL(fileURLWithPath: "/l"))))
}
