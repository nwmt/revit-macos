// The trackpad helper through LaunchServices: <App>.app/Contents/Helpers/<App> Trackpad.app, its own bundle ID, so the
// permission macOS gives is the helper's alone (spec §1, step 0). Its ends come back as NSWorkspace notifications.
import AppCore
import AppKit
import TrackpadState

@MainActor final class MacHelperLauncher: HelperLauncher {
    let url: URL, id: String
    var onExit: ((HelperInstance) -> Void)?

    init(appName: String) {
        url = Bundle.main.bundleURL.appending(path: "Contents/Helpers/\(appName) Trackpad.app")
        id = (Bundle.main.bundleIdentifier ?? "") + ".trackpad"
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                                          queue: .main) { [weak self] n in
            guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let h = MacHelperLauncher.instance(a)
            MainActor.assumeIsolated {
                guard let self, a.bundleIdentifier == self.id else { return }
                self.onExit?(h)
            }
        }
    }

    nonisolated static func instance(_ a: NSRunningApplication) -> HelperInstance {
        HelperInstance(pid: a.processIdentifier, start: a.launchDate.map { String($0.timeIntervalSince1970) } ?? "")
    }

    func running() -> [HelperInstance] { NSRunningApplication.runningApplications(withBundleIdentifier: id).map(Self.instance) }
    func terminate(_ h: HelperInstance) { NSRunningApplication(processIdentifier: h.pid)?.terminate() }
    func forceTerminate(_ h: HelperInstance) { NSRunningApplication(processIdentifier: h.pid)?.forceTerminate() }

    func launch(_ args: HelperArgs) async throws -> HelperInstance {
        let c = NSWorkspace.OpenConfiguration()
        c.arguments = args.argv(); c.activates = false; c.addsToRecentItems = false
        c.allowsRunningApplicationSubstitution = false; c.createsNewApplicationInstance = false
        let a = try await NSWorkspace.shared.openApplication(at: url, configuration: c)
        return Self.instance(a)
    }
}

struct MacPermissionResetter: PermissionResetter {
    func reset(bundleID: String) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil"); p.arguments = ["reset", "Accessibility", bundleID]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { cont.resume(returning: false); return }
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0)
            }
        }
    }
}
