// What the trackpad helper's coordinator needs from macOS, as ports: TrackpadHelper implements them, the tests fake
// them. Everything the system tells the helper (an app launched or ended, the screens changed, a timer) arrives on the
// main thread, so the ports that carry it are main-actor ones.
import CoreGraphics
import Foundation
import TrackpadCore
import TrackpadState

@MainActor public protocol WorkspacePort {
    func runningRevitPids() -> Set<Int32>
}

@MainActor public protocol PermissionPort {
    func trusted() -> Bool                  // Accessibility (macOS 27: Device Control and Data Access)
    func prompt()                           // macOS's own dialog, once
}

@MainActor public protocol TapPort {
    func create() -> Bool
    /// A zero scroll with our tag; true when the tap saw it come back within TrackpadConstants.postingProbe.
    func probePosting() async -> Bool
    func disable()
    func post(_ posts: [Post])
    func setContext(_ c: DecideContext)
    /// Hands the cancel to the gesture machine on the tap's thread and returns once its posts (the middle button's up)
    /// are sent.
    func cancel(_ r: CancelReason) async
    func cursor() -> CGPoint
}

public struct EngineBottle: Equatable, Sendable {
    public let bottle: String, year: Int, pids: [Int32]
    public init(bottle: String, year: Int, pids: [Int32]) { self.bottle = bottle; self.year = year; self.pids = pids }
}

public protocol EnginePort: Sendable {
    func status() async -> [EngineBottle]   // revit status --json
}

@MainActor public protocol DisplayPort {
    func union() -> CGRect                  // every screen together, in points
}

/// A bottle's hittest client as the coordinator drives it (HittestClient, or a fake).
public protocol HelperClient: HitQuerying {
    func start()
    func stop()
    func restart()
    func shutdown()                         // stop and wait for its processes (the helper is exiting)
}

extension HittestClient: HelperClient {}

@MainActor public protocol ClientFactory {
    func make(year: Int, bottle: String, scale: @escaping @Sendable (CGRect) -> Int?) -> any HelperClient
}

@MainActor public protocol StatePort {
    func write(_ s: HelperState)
}

public protocol ClockPort: Sendable {
    func now() -> Double                    // seconds, monotonic
    func sleep(_ seconds: Double) async
}

public struct HelperPorts {
    public let workspace: any WorkspacePort, permission: any PermissionPort, tap: any TapPort, engine: any EnginePort
    public let display: any DisplayPort, clients: any ClientFactory, state: any StatePort, clock: any ClockPort
    public let log: TrackpadLog
    public init(workspace: any WorkspacePort, permission: any PermissionPort, tap: any TapPort, engine: any EnginePort,
                display: any DisplayPort, clients: any ClientFactory, state: any StatePort, clock: any ClockPort,
                log: TrackpadLog) {
        self.workspace = workspace; self.permission = permission; self.tap = tap; self.engine = engine
        self.display = display; self.clients = clients; self.state = state; self.clock = clock; self.log = log
    }
}
