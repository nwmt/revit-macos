// A fake of the trackpad helper's launcher: running instances, launches (optionally held), terminations on request.
import Foundation
@testable import AppCore
import TrackpadState

@MainActor final class FakeHelperLauncher: HelperLauncher {
    var instances: [HelperInstance] = []
    var launched: [HelperArgs] = []
    var calls: [String] = []
    var quitsOnTerminate = true, quitsOnForce = true
    var holding = false
    private var gate: CheckedContinuation<Void, Never>?
    private var next: Int32 = 900

    func running() -> [HelperInstance] { instances }
    func terminate(_ h: HelperInstance) { calls.append("terminate \(h.pid)"); if quitsOnTerminate { gone(h) } }
    func forceTerminate(_ h: HelperInstance) { calls.append("force \(h.pid)"); if quitsOnForce { gone(h) } }
    func gone(_ h: HelperInstance) { instances.removeAll { $0 == h } }

    func launch(_ args: HelperArgs) async throws -> HelperInstance {
        calls.append("launch\(args.recoverOnly ? " recover-only" : args.recover ? " recover" : "")")
        launched.append(args)
        if holding { await withCheckedContinuation { gate = $0 } }
        next += 1
        let h = HelperInstance(pid: next, start: "t\(next)")
        instances.append(h)
        return h
    }

    func release() { holding = false; gate?.resume(); gate = nil }
}

final class FakeResetter: PermissionResetter, @unchecked Sendable {
    var ok = true
    var calls: [String] = []
    func reset(bundleID: String) async -> Bool { calls.append(bundleID); return ok }
}
