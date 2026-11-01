// The main window: Library, one page per Revit bottle, Activity. Everything decides through the models in AppCore.
import AppCore
import AppKit
import SwiftUI

struct MainWindow: View {
    let app: AppModel
    let env: AppEnvironment

    var body: some View {
        @Bindable var router = env.router
        NavigationSplitView {
            Sidebar(app: app, env: env).navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            switch router.place {
            case .library: LibraryView(app: app, env: env)
            case .activity: ActivityView(app: app, env: env)
            case .bottle(let ref): VersionView(app: app, env: env, ref: ref).id(ref)   // a draft belongs to its bottle
            }
        }
        .frame(minWidth: 960, minHeight: 560)
        .sheet(item: $router.sheet) { PlanSheet(app: app, env: env, request: $0) }
        .sheet(item: $router.recover, onDismiss: { env.router.recoverGone() }) { RecoverSheet(app: app, env: env, ref: $0) }
    }
}

struct Sidebar: View {
    let app: AppModel
    let env: AppEnvironment

    var body: some View {
        let content = LibraryContent.make(status: app.status, watched: app.watched, starting: Set(app.revitStarting.keys))
        List(selection: Binding<Place?>(get: { env.router.place }, set: { if let p = $0 { env.router.place = p } })) {
            Label("Library", systemImage: "square.grid.2x2").tag(Place.library)
            Section("Revit") {
                ForEach(content.cards, id: \.bottle) { c in
                    HStack {
                        Text("Revit \(String(c.year))")
                        if !c.bottle.hasSuffix("-a") { Text(c.bottle).foregroundStyle(.secondary) }
                        Spacer()
                        if c.taskHere { ProgressView().controlSize(.small) }
                        else if c.running { Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.tint) }
                    }
                    .tag(Place.bottle(c.ref))
                }
            }
            Section {
                HStack {
                    Label("Activity", systemImage: "waveform.path.ecg")
                    Spacer()
                    if app.isBusy { Text("1").font(.caption.bold()).foregroundStyle(.secondary) }
                }
                .tag(Place.activity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Button { env.router.open(.wizard) } label: { Label("Add Revit version", systemImage: "plus") }
                    .buttonStyle(.plain).disabled(app.isBusy)
                if let s = app.status { Text(toolsLine(s)).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toolsLine(_ s: EngineStatus) -> String {
        let cx = s.crossover.found ? String(localized: "CrossOver \(s.crossover.version)") : String(localized: "No CrossOver")
        return "\(cx) · \(s.rosetta ? String(localized: "Rosetta") : String(localized: "No Rosetta"))"
    }
}

/// Open and Show Revit: one path for the menu, the Library, the version page and the end of an install.
@MainActor enum RevitActions {
    static func open(app: AppModel, year: Int, bottle: String, viewer: Bool = false) async {
        switch await app.open(year: year, bottle: bottle, viewer: viewer) {
        case .starting: break
        case .running(let pids): show(pids)
        case .refused(let why): Confirm.tell(String(localized: "Revit \(String(year)) did not start."), why)
        }
    }

    /// Never the app in ~/Applications: it would start a second Revit.
    static func show(_ pids: [Int32]) {
        // activation is cooperative: this app hands it over, or macOS refuses
        let apps = pids.compactMap { NSRunningApplication(processIdentifier: $0) }
        apps.forEach { NSApp.yieldActivation(to: $0) }
        if !apps.contains(where: { $0.activate(from: .current, options: .activateAllWindows) }) {
            Confirm.tell(String(localized: "Could not bring Revit to the front."), "")
        }
    }
}

struct RevitButton: View {
    let app: AppModel
    let year: Int
    let bottle: String
    let running: Bool
    let pids: [Int32]
    let blocked: Bool

    var body: some View {
        if running {
            Button("Show Revit") { RevitActions.show(pids) }.buttonStyle(.borderedProminent)
        } else if app.revitStarting[bottle] != nil {
            Button("Starting…") {}.buttonStyle(.borderedProminent).disabled(true)
        } else {
            Button("Open") { Task { await RevitActions.open(app: app, year: year, bottle: bottle) } }
                .buttonStyle(.borderedProminent).disabled(blocked)
        }
    }
}

struct StatusPill: View {
    let status: String
    var body: some View {
        Text(StatusWords.of(status)).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
    private var color: Color { status == "works" ? .green : status == "mostly" ? .orange : .secondary }
}
