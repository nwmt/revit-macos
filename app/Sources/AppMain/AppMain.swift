// The menu bar app: a menu (MenuBarExtra) and its windows — the progress of a run, the first-run wizard, the add-ins of
// a bottle, the settings. Every decision is the engine's (AppCore's models ask it); these views only draw and ask.
// The name comes from Info.plist (app/app.conf), never from this file.
import AppCore
import AppKit
import SwiftUI

@main
struct AppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var env = AppEnvironment()

    var body: some Scene {
        MenuBarExtra {
            if let app = env.app {
                MenuView(app: app, env: env)
            } else {
                Text("The app is incomplete. Download it again.")
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        } label: {
            MenuLabel(env: env)
        }
        .menuBarExtraStyle(.menu)

        Window("Progress", id: Route.run.id) {
            if let app = env.app { RunWindow(app: app, env: env).appWindow(env) }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)   // started by a file, SwiftUI would open the first of these by itself

        Window("Add Revit", id: Route.wizard.id) {
            if let app = env.app { WizardWindow(app: app, env: env).appWindow(env) }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)   // started by a file, SwiftUI would open the first of these by itself

        WindowGroup("Add-ins", id: "addins", for: BottleRef.self) { $ref in
            if let app = env.app, let ref { AddinsWindow(app: app, env: env, ref: ref).appWindow(env) }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)   // started by a file, SwiftUI would open the first of these by itself

        Window("Settings", id: Route.settings.id) {
            if let app = env.app { SettingsWindow(app: app, env: env).appWindow(env) }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)   // started by a file, SwiftUI would open the first of these by itself
    }
}

/// What every view needs: the app model (nil when the bundle has no engine), the window router, the app's name and
/// repository from Info.plist.
@MainActor @Observable final class AppEnvironment {
    let router = WindowRouter()
    let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
    let repo = Bundle.main.object(forInfoDictionaryKey: "AppRepository") as? String ?? ""
    let app: AppModel?
    let wizard: WizardModel?
    let settings: SettingsModel?
    let trackpad: TrackpadModel?
    let theme: ThemeSync?
    let files: FileOpenModel?
    /// What the menu shows. Rebuilding an open menu closes its submenus, so it is updated only while no menu is open
    /// (AppKit says when menu tracking begins and ends) and only when it differs.
    private(set) var menu: MenuContent?
    @ObservationIgnored private var menuOpen = false
    @ObservationIgnored private var openWindows = 0

    /// While a window of the app is open the app is a regular one (a Dock icon, Cmd-Tab), so another app's dialog cannot
    /// bury its window; when the last one closes it is a menu bar app again.
    func windowAppeared() {
        openWindows += 1
        if openWindows == 1 { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
    }

    func windowGone() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 { NSApp.setActivationPolicy(.accessory) }
    }

    func syncMenu() {
        guard !menuOpen, let app else { return }
        let m = MenuContent.make(status: app.status, watched: app.watched, failure: app.failure, busy: app.isBusy,
                                 trackpad: trackpad?.line ?? .off)
        if m != menu { menu = m }
    }

    /// A GitHub API GET; anything but 200 is an error.
    nonisolated static func fetch(_ url: URL) async throws -> Data {
        var r = URLRequest(url: url); r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return d
    }

    init() {
        let env = ProcessInfo.processInfo.environment
        if let engine = EngineLocator.find(resources: Bundle.main.resourceURL, env: env) {
            let notifier = UserNotifier(router: router)
            // REVIT_DATA (dev, the demo) wins over the data folder the bundled engine reports
            let m = AppModel(engine: ProcessEngine(engine: engine, environment: EngineEnvironment.make(from: env)),
                           defaults: .standard, notifier: notifier, dataOverride: env["REVIT_DATA"].map { URL(fileURLWithPath: $0) })
            app = m
            wizard = WizardModel(app: m, system: MacSystemActions())
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            settings = SettingsModel(app: m, login: LoginItemService(), updates: UpdateChecker(repo: repo, current: version, fetch: Self.fetch),
                                     defaults: .standard)
            let launcher = MacHelperLauncher(appName: name), pe = ProcessEngine(engine: engine, environment: [:])
            let t = TrackpadModel(launcher: launcher, resetter: MacPermissionResetter(), defaults: .standard, engine: engine,
                                  data: { [weak m] in m?.dataFolder }, placement: { [weak m] in m?.status?.app?.placement },
                                  parent: { await pe.processStart(pid: getpid()).map { (getpid(), $0) } },
                                  helperID: launcher.id)
            launcher.onExit = { [weak t] h in Task { await t?.helperExited(h) } }
            trackpad = t
            theme = ThemeSync(engine: ProcessEngine(engine: engine, environment: EngineEnvironment.make(from: env)))
            files = FileOpenModel(engine: ProcessEngine(engine: engine, environment: EngineEnvironment.make(from: env)),
                                  ask: FileOpenDialogs(router: router))
        } else {
            app = nil
            wizard = nil
            settings = nil
            trackpad = nil
            theme = nil
            files = nil
        }
        FileInbox.receive = { [weak self] urls in Task { await self?.files?.add(urls) } }
        // the Mac turned light or dark: Revit 2027 follows (ThemeSync)
        DistributedNotificationCenter.default().addObserver(forName: .init("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.theme?.appearanceChanged(); self?.theme?.kick() }
        }
        for (name, open) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuOpen = open; if !open { self?.syncMenu() } }
            }
        }
    }
}

/// The menu bar icon. It stays for the app's whole life, so it runs the launch, the poll loop and the window requests.
struct MenuLabel: View {
    let env: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "building.columns")
            .task { await run() }
            .onChange(of: env.router.pending) { _, r in
                guard let r else { return }
                env.router.pending = nil
                switch r {
                case .addins(let ref): openWindow(id: "addins", value: ref)
                default: openWindow(id: r.id)
                }
                NSApp.activate()
            }
    }

    private func run() async {
        guard let app = env.app else { return }
        await app.launch()
        await env.trackpad?.start()
        env.syncMenu()
        if app.status?.app?.placement == "move" { Placement.ask(name: env.name) }
        if app.watched != nil {
            env.router.open(.run)
        } else if (app.status?.bottles ?? []).isEmpty && !app.isBusy && FileInbox.early.isEmpty {
            env.router.open(.wizard)   // started for a file: its dialog offers the wizard
        }
        await env.files?.add(FileInbox.early); FileInbox.early = []
        Task { await env.files?.start() }   // the poll loop must not wait for Revit to take a file
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            await app.poll()
            if tick % 2 == 0 {
                env.trackpad?.refresh()
                env.theme?.update(bottles: app.status?.bottles ?? []); env.theme?.kick()   // returns at once
            }
            env.syncMenu()
            tick += 1
            if tick % 60 == 1, !env.repo.isEmpty { await env.settings?.checkUpdatesIfDue(now: Date()) }   // once a minute; it checks once a day
        }
    }
}
