// The app: a menu (MenuBarExtra) and its windows — the main window (Library, a page per Revit, Activity), the first-run
// wizard, the settings. Every decision is the engine's (AppCore's models ask it); these views only draw and ask.
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

        Window(env.name, id: Route.main.id) {
            if let app = env.app { MainWindow(app: app, env: env).appWindow(env) }
        }
        .defaultLaunchBehavior(.suppressed)   // only the router opens windows: a login or a file opens none
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])   // a file from Finder is the delegate's: SwiftUI would show this window for it
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { env.router.open(.settings) }.keyboardShortcut(",")
            }
        }

        Window("Add Revit", id: Route.wizard.id) {
            if let app = env.app { WizardWindow(app: app, env: env).appWindow(env) }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])   // a file from Finder is the delegate's: SwiftUI would show this window for it

        Window("Settings", id: Route.settings.id) {
            if let app = env.app { SettingsWindow(app: app, env: env).appWindow(env) }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])   // a file from Finder is the delegate's: SwiftUI would show this window for it
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
    let warm: WarmModel?
    /// What the menu shows. Rebuilding an open menu closes its submenus, so it is updated only while no menu is open
    /// (AppKit says when menu tracking begins and ends) and only when it differs.
    private(set) var menu: MenuContent?
    @ObservationIgnored private var menuOpen = false
    @ObservationIgnored private var openWindows = 0

    /// With the Dock icon on the app is always a regular one. Menu bar only: while a window of the app is open it is a
    /// regular one (a Dock icon, Cmd-Tab), so another app's dialog cannot bury its window; when the last one closes it is
    /// a menu bar app again.
    func windowAppeared() {
        openWindows += 1
        if openWindows == 1 { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
    }

    func windowGone() {
        openWindows = max(0, openWindows - 1)
        dockChoiceChanged()
    }

    func dockChoiceChanged() {
        NSApp.setActivationPolicy(openWindows > 0 || SettingsModel.showsInDock(.standard) ? .regular : .accessory)
    }

    func syncMenu() {
        guard !menuOpen, let app else { return }
        let m = MenuContent.make(status: app.status, watched: app.watched, failure: app.failure, busy: app.isBusy,
                                 trackpad: trackpad?.line ?? .off, starting: Set(app.revitStarting.keys), recent: app.recent)
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
            let w = WarmModel(engine: ProcessEngine(engine: engine, environment: EngineEnvironment.make(from: env)))
            warm = w
            LaunchInfo.quitting = { w.cancel(); TokenClipboard.shared.clear() }
        } else {
            app = nil
            warm = nil
            wizard = nil
            settings = nil
            trackpad = nil
            theme = nil
            files = nil
        }
        LaunchInfo.reopen = { [router] in router.open(.main) }
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
            .onChange(of: env.router.pending) { go() }
    }

    private func go() {
        guard let r = env.router.pending else { return }
        env.router.pending = nil
        openWindow(id: r.id)
        NSApp.activate()
    }

    private func run() async {
        go()   // a reopen or a click may have come before this view
        guard let app = env.app else { return }
        await app.launch()
        await env.trackpad?.start()
        env.syncMenu()
        if app.status?.app?.placement == "move" { Placement.ask(name: env.name) }
        switch LaunchRoute.pick(activeRun: app.watched != nil, forFile: FileInbox.opened, loginItem: LaunchInfo.loginItem,
                                noBottles: (app.status?.bottles ?? []).isEmpty, busy: app.isBusy, showInDock: SettingsModel.showsInDock(.standard)) {
        case .activity: env.router.open(.run)
        case .wizard: env.router.open(.wizard)
        case .main: env.router.open(.main)
        case .nothing: break
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
