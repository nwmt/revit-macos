// The menu: one submenu per Revit bottle, the activity line, Open the app, Add Revit version, Close all, Settings, Help, Quit.
// Nothing that deletes: Rebuild and Remove are on the Revit's page.
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
        if let t = m.trackpad {
            Button("⚠︎ \(t)") { env.router.open(.settings) }
            Divider()
        }
        Button("Open \(env.name)") { env.router.open(.main) }
        Button("Add Revit version…") { env.router.open(.wizard) }.disabled(!m.changesEnabled)
        Button("Close all…") { Task { await Confirm.closeAll(app: app) } }.disabled(!m.changesEnabled)
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
        Task { await app.sweep(notify: false); NSApplication.shared.terminate(nil) }   // what was left running goes too
    }
}

struct BottleMenu: View {
    let app: AppModel
    let env: AppEnvironment
    let item: BottleItem
    let changes: Bool
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private var ref: BottleRef { BottleRef(year: item.year, bottle: item.bottle) }

    var body: some View {
        if item.running {
            Button("Show Revit") { RevitActions.show(item.pids) }
        } else if item.starting {
            Button("Starting…") {}.disabled(true)
        } else {
            Button("Open Revit") { Task { await RevitActions.open(app: app, year: item.year, bottle: item.bottle) } }
        }
        if !item.recent.isEmpty {
            Menu("Open Recent") {
                ForEach(item.recent, id: \.path) { f in
                    Button(f.name) { if let p = f.path { Task { await env.files?.add([URL(fileURLWithPath: p)]) } } }
                }
            }
        }
        let viewer = AppLinks.viewerApp(year: item.year, bottle: item.bottle, home: home)
        if !item.running, !item.starting, FileManager.default.fileExists(atPath: viewer.path) {
            Button("Open Revit Viewer") { Task { await RevitActions.open(app: app, year: item.year, bottle: item.bottle, viewer: true) } }
                .disabled(!changes)
        }
        Button("Revit \(String(item.year)) in \(env.name)…") { env.router.page(ref) }
        Divider()
        if item.running { Button("Revit not responding?…") { env.router.recover(ref) } }
        Button("Force quit…") { forceQuit() }.disabled(!changes)
    }

    private func forceQuit() {
        guard Confirm.ask(String(localized: "Force quit Revit \(String(item.year))?"),
                          String(localized: "Unsaved work in Revit \(String(item.year)) will be lost."),
                          button: String(localized: "Force quit"), destructive: true) else { return }
        Task { await Confirm.start(app: app, env: env, .stop(year: item.year, bottle: item.bottle)) }
    }
}
