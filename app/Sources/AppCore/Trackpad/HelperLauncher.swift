// How the app starts and ends the trackpad helper (<App> Trackpad.app in Contents/Helpers) and resets its permission:
// protocols, so TrackpadModel can be tested without macOS doing it.
import Foundation
import TrackpadState

public struct HelperInstance: Hashable, Sendable {
    public let pid: Int32
    public let start: String
    public init(pid: Int32, start: String) { self.pid = pid; self.start = start }
}

@MainActor public protocol HelperLauncher {
    func running() -> [HelperInstance]
    func terminate(_ h: HelperInstance)          // asks it to quit (it lets the middle button go first)
    func forceTerminate(_ h: HelperInstance)
    func launch(_ args: HelperArgs) async throws -> HelperInstance
}

/// tccutil reset Accessibility <the helper's bundle ID>: macOS forgets an old permission that no longer fits the helper.
public protocol PermissionResetter: Sendable {
    func reset(bundleID: String) async -> Bool
}
