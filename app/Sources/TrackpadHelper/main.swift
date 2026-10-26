// <App> Trackpad: the menu bar app's helper that makes the trackpad pan, orbit and zoom in Revit's views (spec
// 2026-10-26-trackpad). It has a permission of its own (Accessibility), so the app and the engine have none. The app
// starts it with HelperArgs and ends it with terminate(); it ends by itself when the app is gone. The work is the
// coordinator's (TrackpadIO); here only macOS is wired to it: notifications, timers, signals.
import AppKit
import TrackpadCore
import TrackpadIO
import TrackpadState

signal(SIGPIPE, SIG_IGN)   // a hittest pipe that closes must not end the helper
guard let args = HelperArgs.parse(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data("usage: --session <token> --parent <pid>:<start> --engine <revit> --data <folder> [--recover | --recover-only]\n".utf8))
    exit(2)
}
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
    exit(0)   // one helper at a time: the app waits for the old one to end before it starts a new one
}

/// The process's start time as ps prints it (the app passes its own this way).
func started(_ pid: Int32) -> String? {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-o", "lstart=", "-p", String(pid)]
    p.environment = ["LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin"]
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

@MainActor final class Helper: NSObject, NSApplicationDelegate {
    let args: HelperArgs
    init(args: HelperArgs) { self.args = args }
    var coordinator: HelperCoordinator!
    var timers: [Timer] = []
    var term: DispatchSourceSignal?
    nonisolated(unsafe) static weak var current: Helper?

    func applicationDidFinishLaunching(_ n: Notification) {
        Helper.current = self
        let args = args
        guard started(args.parentPid) == args.parentStart.trimmingCharacters(in: .whitespaces) else { exit(0) }   // the app that started us is gone
        let log = TrackpadLog(url: args.data.appending(path: "logs/trackpad.log"))
        let tap = TapThread(log: log)
        let env = engineEnvironment(from: ProcessInfo.processInfo.environment)
        let ports = HelperPorts(workspace: MacWorkspace(), permission: MacPermission(), tap: MacTap(tap),
                                engine: EngineStatusReader(engine: args.engine, environment: env), display: MacDisplay(),
                                clients: MacClients(engine: args.engine, environment: env, log: log),
                                state: MacState(args.data.appending(path: "trackpad/state.json")), clock: MacClock(), log: log)
        let c = HelperCoordinator(args: args, ports: ports, pid: getpid(), start: started(getpid()) ?? "")
        c.onExit = { exit(0) }
        coordinator = c
        tap.onDisabled = { Task { @MainActor in await Helper.current?.coordinator.tapDisabledByMacOS() } }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, isRevit(a) else { return }
            let pid = a.processIdentifier
            Task { @MainActor in await Helper.current?.coordinator.revitLaunched(pid) }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, isRevit(a) else { return }
            let pid = a.processIdentifier
            Task { @MainActor in await Helper.current?.coordinator.revitTerminated(pid) }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = a.processIdentifier
            Task { @MainActor in await Helper.current?.coordinator.activated(pid) }
        }
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async { Helper.current?.screensChanged() }
        }, nil)
        timers.append(Timer.scheduledTimer(withTimeInterval: TrackpadConstants.permissionCheck, repeats: true) { _ in
            Task { @MainActor in
                guard let h = Helper.current else { return }
                if kill(args.parentPid, 0) != 0 { await h.coordinator.shutdown(reason: "the app is gone"); return }
                await h.coordinator.syncRevits()
                await h.coordinator.checkPermission()
            }
        })
        signal(SIGTERM, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        s.setEventHandler { Task { @MainActor in await Helper.current?.coordinator.shutdown(reason: "TERM") } }
        s.resume(); term = s
        Task { await c.start() }
    }

    private var screensPending = false
    /// One display change comes as a callback per screen: they are taken together, half a second later.
    func screensChanged() {
        guard !screensPending else { return }
        screensPending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            screensPending = false
            await coordinator.displaysChanged()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await coordinator.shutdown(reason: "quit") }   // it exits when done
        return .terminateCancel
    }
}

let app = NSApplication.shared
let helper = Helper(args: args)
app.delegate = helper
app.setActivationPolicy(.accessory)
app.run()
