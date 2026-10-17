// The menu (spec §3): one submenu per Revit bottle, the activity line, Add Revit version, Settings, Help, Quit.
// Items that change something are off while the engine is busy.
import AppCore
import AppKit
import SwiftUI

struct MenuView: View {
    let app: AppModel
    let env: AppEnvironment

    var body: some View {
        // the snapshot, not the model: it does not change while a menu is open, so an open submenu stays open
        let m = env.menu ?? MenuContent.make(status: nil, watched: nil, failure: nil, busy: true)
        ForEach(m.bottles, id: \.bottle) { b in
            Menu(b.running ? "\(b.title)  ●" : b.title) { BottleMenu(app: app, env: env, item: b, changes: m.changesEnabled) }
        }
        if !m.bottles.isEmpty { Divider() }
        if let a = m.activity {
            Button(a.isFailure ? "⚠︎ \(a.title)" : a.title) { env.router.open(.run) }
            Divider()
        }
        Button("Add Revit version…") { env.router.open(.wizard) }.disabled(!m.changesEnabled)
        Divider()
        Button("Settings…") { env.router.open(.settings) }
        Button("Help") { if !env.repo.isEmpty { NSWorkspace.shared.open(AppLinks.readme(repo: env.repo)) } }
        Button("Copy diagnostic report") { Task { await Report.copy(app: app, year: nil, bottle: nil, logDir: nil) } }
        Divider()
        Button("Quit \(env.name)") { quit() }
    }

    private func quit() {
        if let w = app.watched, w.phase == .running, w.state.end == nil,
           !Confirm.ask(String(localized: "Quit \(env.name)?"), String(localized: "The task goes on in the background."),
                        button: String(localized: "Quit"), destructive: false) { return }
        NSApplication.shared.terminate(nil)
    }
}

struct BottleMenu: View {
    let app: AppModel
    let env: AppEnvironment
    let item: BottleItem
    let changes: Bool
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    var body: some View {
        Button("Open Revit") { NSWorkspace.shared.open(AppLinks.revitApp(year: item.year, bottle: item.bottle, home: home)) }
        let viewer = AppLinks.viewerApp(year: item.year, bottle: item.bottle, home: home)
        if FileManager.default.fileExists(atPath: viewer.path) {
            Button("Open Revit Viewer") { NSWorkspace.shared.open(viewer) }
        }
        Button("Add-ins…") { env.router.open(.addins(BottleRef(year: item.year, bottle: item.bottle))) }.disabled(!changes)
        Button("Force quit…") { forceQuit() }.disabled(!changes)
        Button("Show logs") { showLogs() }
        Button("Copy diagnostic report") { Task { await Report.copy(app: app, year: item.year, bottle: item.bottle, logDir: nil) } }
        Divider()
        Button("Rebuild…") { Task { await Confirm.plan(app: app, env: env, .rebuild(year: item.year, bottle: item.bottle, source: nil)) } }
            .disabled(!changes)
        Button("Remove…") { Task { await Confirm.plan(app: app, env: env, .remove(year: item.year, bottle: item.bottle)) } }
            .disabled(!changes)
    }

    private func forceQuit() {
        guard Confirm.ask(String(localized: "Force quit Revit \(String(item.year))?"),
                          String(localized: "Unsaved work in Revit \(String(item.year)) will be lost."),
                          button: String(localized: "Force quit"), destructive: true) else { return }
        Task { await Confirm.start(app: app, env: env, .stop(year: item.year, bottle: item.bottle)) }
    }

    private func showLogs() {
        guard let data = app.dataFolder else { return }
        let l = AppLinks.logs(data: data, bottle: item.bottle)
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: l.path) ? l : AppLinks.logs(data: data, bottle: nil))
    }
}
