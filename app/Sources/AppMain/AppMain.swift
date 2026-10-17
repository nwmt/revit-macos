// The menu bar app: a menu (MenuBarExtra) and its windows — the progress of a run, the first-run wizard, the add-ins of
// a bottle, the settings. Every decision is the engine's (AppCore's models ask it); these views only draw and ask.
// The name comes from Info.plist (app/app.conf), never from this file.
import AppCore
import AppKit
import SwiftUI

@main
struct AppMain: App {
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
            if let app = env.app { RunWindow(app: app, env: env) }
        }
        .windowResizability(.contentSize)

        Window("Add Revit", id: Route.wizard.id) {
            if let app = env.app { WizardWindow(app: app, env: env) }
        }
        .windowResizability(.contentSize)

        WindowGroup("Add-ins", id: "addins", for: BottleRef.self) { $ref in
            if let app = env.app, let ref { AddinsWindow(app: app, env: env, ref: ref) }
        }
        .windowResizability(.contentSize)

        Window("Settings", id: Route.settings.id) {
            if let app = env.app { SettingsWindow(app: app, env: env) }
        }
        .windowResizability(.contentSize)
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
    /// What the menu shows. Rebuilding an open menu closes its submenus, so it is updated only while no menu is open
    /// (AppKit says when menu tracking begins and ends) and only when it differs.
    private(set) var menu: MenuContent?
    @ObservationIgnored private var menuOpen = false

    func syncMenu() {
        guard !menuOpen, let app else { return }
        let m = MenuContent.make(status: app.status, watched: app.watched, failure: app.failure, busy: app.isBusy)
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
        } else {
            app = nil
            wizard = nil
            settings = nil
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
        env.syncMenu()
        if app.status?.app?.placement == "move" { Placement.ask(name: env.name) }
        if app.watched != nil {
            env.router.open(.run)
        } else if (app.status?.bottles ?? []).isEmpty && !app.isBusy {
            env.router.open(.wizard)
        }
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            await app.poll()
            env.syncMenu()
            tick += 1
            if tick % 60 == 1, !env.repo.isEmpty { await env.settings?.checkUpdatesIfDue(now: Date()) }   // once a minute; it checks once a day
        }
    }
}
