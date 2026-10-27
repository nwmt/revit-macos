// The coordinator's ports on macOS: thin adapters, no decisions (those are in TrackpadIO and TrackpadCore).
import AppKit
import ApplicationServices
import CoreGraphics
import TrackpadCore
import TrackpadIO
import TrackpadState

/// Revit as macOS sees a Wine process: an app named Revit.exe.
func isRevit(_ a: NSRunningApplication) -> Bool {
    (a.localizedName ?? a.executableURL?.lastPathComponent ?? "").caseInsensitiveCompare("Revit.exe") == .orderedSame
}

@MainActor final class MacWorkspace: WorkspacePort {
    func runningRevitPids() -> Set<Int32> { Set(NSWorkspace.shared.runningApplications.filter(isRevit).map(\.processIdentifier)) }
}

@MainActor final class MacPermission: PermissionPort {
    func trusted() -> Bool { AXIsProcessTrusted() }
    func prompt() { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
}

@MainActor final class MacTap: TapPort {
    let thread: TapThread
    init(_ t: TapThread) { thread = t }
    func create() -> Bool { thread.create() }
    func probePosting() async -> Bool { await thread.probePosting() }
    func disable() { thread.disable() }
    func post(_ posts: [Post]) { thread.perform { [thread] in thread.post(posts) } }   // its button state is that thread's
    func setContext(_ c: DecideContext) { thread.setContext(c) }
    func cancel(_ r: CancelReason) async { await thread.cancel(r) }
    func cancelAndDisable(_ r: CancelReason) async { await thread.cancelAndDisable(r) }
    func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }
}

@MainActor final class MacDisplay: DisplayPort {
    func union() -> CGRect {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &n) == .success else { return .null }
        return ids.prefix(Int(n)).map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
    }
}

@MainActor final class MacClients: ClientFactory {
    let engine: URL, environment: [String: String], log: TrackpadLog
    init(engine: URL, environment: [String: String], log: TrackpadLog) { self.engine = engine; self.environment = environment; self.log = log }
    func make(year: Int, bottle: String, scale: @escaping @Sendable (CGRect) -> Int?) -> any HelperClient {
        HittestClient(engine: engine, year: year, bottle: bottle, environment: environment, log: log, scale: scale)
    }
}

@MainActor final class MacState: StatePort {
    let url: URL
    init(_ u: URL) { url = u }
    func write(_ s: HelperState) { try? StateFile.write(s, to: url) }
}

struct MacClock: ClockPort {
    func now() -> Double { ProcessInfo.processInfo.systemUptime }
    func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
}
