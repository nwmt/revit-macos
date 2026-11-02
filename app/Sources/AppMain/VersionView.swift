// The page of one Revit: its header and the tabs its year's profile has.
import AppCore
import SwiftUI

struct VersionView: View {
    let app: AppModel
    let env: AppEnvironment
    let ref: BottleRef

    var body: some View {
        if let b = app.status?.bottles.first(where: { $0.name == ref.bottle }) {
            let tabs = VersionTab.of(b)
            let tab = tabs.contains(env.router.tab) ? env.router.tab : .overview
            VStack(alignment: .leading, spacing: 0) {
                header(b).padding(20)
                Picker("", selection: Binding(get: { tab }, set: { env.router.tab = $0 })) {
                    ForEach(tabs, id: \.self) { Text(title($0)).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20)
                Divider().padding(.top, 12)
                ScrollView {
                    Group {
                        switch tab {
                        case .overview: OverviewTab(app: app, env: env, bottle: b, year: ref.year)
                        case .display: DisplayKeysTab(app: app, env: env, ref: ref, bottle: b)
                        case .drive: GoogleDriveTab(app: app, env: env, ref: ref, bottle: b)
                        case .addins: AddinsTab(app: app, env: env, ref: ref)
                        case .ai: AiTab(app: app, env: env, ref: ref, bottle: b)
                        case .maintenance: MaintenanceTab(app: app, env: env, ref: ref, bottle: b)
                        }
                    }
                    .padding(20).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("Revit \(String(ref.year))")
        } else {
            ContentUnavailableView("This Revit is gone.", systemImage: "questionmark.folder")
        }
    }

    private func header(_ b: Bottle) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Revit \(String(ref.year))").font(.title2.bold())
                    StatusPill(status: b.support?.status ?? "untested")
                    if b.running { Text("Running").font(.caption).foregroundStyle(.tint) }
                }
                Text(b.support.map { "\(b.name) · \($0.tested)" } ?? b.name).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if b.running {
                Button("Revit not responding?") { env.router.recover(ref) }.buttonStyle(.link)
                Button("Force quit…") { forceQuit() }.disabled(app.isBusy)
            }
            RevitButton(app: app, env: env, year: ref.year, bottle: ref.bottle, running: b.running, pids: b.revitPids, blocked: app.isBusy)
        }
    }

    private func forceQuit() {
        guard Confirm.ask(String(localized: "Force quit Revit \(String(ref.year))?"),
                          String(localized: "Unsaved work in Revit \(String(ref.year)) will be lost."),
                          button: String(localized: "Force quit"), destructive: true) else { return }
        Task { await Confirm.start(app: app, env: env, .stop(year: ref.year, bottle: ref.bottle)) }
    }

    private func title(_ t: VersionTab) -> String {
        switch t {
        case .overview: String(localized: "Overview")
        case .display: String(localized: "Display & Keys")
        case .drive: String(localized: "Google Drive")
        case .addins: String(localized: "Add-ins")
        case .ai: String(localized: "AI Assistant")
        case .maintenance: String(localized: "Maintenance")
        }
    }
}

private struct OverviewTab: View {
    let app: AppModel
    let env: AppEnvironment
    let bottle: Bottle
    let year: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How Revit \(String(year)) runs on a Mac").font(.headline)
            HStack(spacing: 8) {
                StatusPill(status: bottle.support?.status ?? "untested")
                if let t = bottle.support?.tested, !t.isEmpty { Text("tested on \(t)").foregroundStyle(.secondary) }
            }
            if let g = bottle.support?.gaps, !g.isEmpty { Label(g, systemImage: "info.circle") }
            if !env.repo.isEmpty, let u = URL(string: "https://github.com/\(env.repo)/blob/main/versions/\(year).md") {
                Link("All notes for Revit \(String(year))", destination: u)
            }
            if let files = app.recent[bottle.name], !files.isEmpty {
                Text("Recent projects").font(.headline).padding(.top, 12)
                RecentList(env: env, files: files, limit: 8)
            }
        }
        .task(id: bottle.running) { await app.refreshRecent(bottle) }
    }
}

private struct AddinsTab: View {
    let app: AppModel
    let env: AppEnvironment
    let ref: BottleRef
    @State private var model: AddinsModel?

    var body: some View {
        Group {
            if let model { AddinsView(model: model, app: app, env: env) } else { ProgressView() }
        }
        .task(id: ref) {
            let m = AddinsModel(app: app, system: MacSystemActions(), year: ref.year, bottle: ref.bottle)
            model = m
            await m.load()
        }
    }
}

private struct DisplayKeysTab: View {
    let app: AppModel
    let env: AppEnvironment
    let ref: BottleRef
    let bottle: Bottle
    @State private var draft = SettingsDraft([:])

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("retina", "Retina", [("on", "On"), ("compact", "Compact"), ("off", "Off")]) {
                switch $0 {
                case "on": "Sharp text and drawings. Views draw slower."
                case "compact": "Sharp, with smaller text and more room on screen."
                case "off": "Fastest views; text is less sharp."
                default: ""
                }
            }
            group("keys", "Keys", [("mac", "Mac"), ("windows", "Windows")]) {
                switch $0 {
                case "mac": "Cmd+Z, Cmd+S and Cmd+C work as on a Mac."
                case "windows": "Cmd works as Alt."
                default: ""
                }
            }
            group("theme", "Theme", [("mac", "Follow Mac"), ("light", "Light"), ("dark", "Dark")]) {
                switch $0 {
                case "mac": "Light or dark, as your Mac, also while Revit runs."
                case "light": "Always light."
                case "dark": "Always dark."
                default: ""
                }
            }
            steel
            Text("Applies the next time Revit starts. After a Retina change the first start may open the window at another size: maximize it, quit, start again.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if bottle.running { Text("Quit Revit first.").foregroundStyle(.secondary) }
                Spacer()
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
                    .disabled(!draft.canApply(running: bottle.running, busy: app.isBusy))
            }
        }
        .task(id: bottle.settings) { draft = SettingsDraft(bottle.settings) }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { draft.picked[key] ?? "" }, set: { draft.picked[key] = $0 })
    }

    @ViewBuilder private func group(_ key: String, _ label: LocalizedStringKey, _ options: [(String, LocalizedStringKey)],
                                    hint: @escaping (String) -> LocalizedStringKey) -> some View {
        if draft.original[key] != nil {
            VStack(alignment: .leading, spacing: 4) {
                Picker(label, selection: binding(key)) {
                    ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 420)
                if SettingsDraft.options(key).contains(draft.picked[key] ?? "") {
                    Text(hint(draft.picked[key] ?? "")).font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("The settings do not fit together. Pick one.").font(.callout).foregroundStyle(.orange)
                }
            }
        }
    }

    /// The price stays in view whichever way the switch is: speed against tools, and a model that may not open.
    @ViewBuilder private var steel: some View {
        if let s = draft.original["steel"], s != "none" {
            VStack(alignment: .leading, spacing: 6) {
                if s == "missing" {
                    Text("Steel Connections").font(.headline)
                    Text("A Steel Connections file is missing. Rebuild brings it back.").foregroundStyle(.orange)
                    Button("Go to Maintenance") { env.router.tab = .maintenance }
                } else {
                    Picker("Steel Connections", selection: binding("steel")) {
                        Text("On").tag("on"); Text("Off").tag("off")
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 420)
                    Text(SettingsDraft.steelCost(year: ref.year)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if s == "mixed" { Text("Steel Connections is set only in part. On puts it right.").font(.callout).foregroundStyle(.orange) }
                    if s == "off" { Text("If a model stops opening, turn it back on here.").font(.callout) }
                }
            }
        }
    }

    private func apply() {
        if draft.needsSteelConfirm,
           !Confirm.ask(String(localized: "Turn off Steel Connections?"),
                        SettingsDraft.steelCost(year: ref.year) + "\n\n" + String(localized: "If a model stops opening, turn it back on here."),
                        button: String(localized: "Turn Off"), destructive: true) { return }
        let c = draft.changes
        Task { await Confirm.start(app: app, env: env, .set(year: ref.year, bottle: ref.bottle, settings: c)) }
    }
}

/// Lists a folder of G: ahead, because a person named it: Revit's Open dialog then does not wait on each subfolder.
private struct PrepareFolder: View {
    let warm: WarmModel
    let ref: BottleRef
    @State private var folder = ""
    @State private var levels = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open dialog slow on a G: folder?").font(.headline)
            Text("Google Drive fetches each new folder from the internet. Prepare a folder once: its subfolders are listed ahead, so Revit's Open dialog doesn't wait. It can run while Revit is open.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("G:\\Shared drives\\Team\\Projects", text: $folder).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                Button("Choose…") { choose() }
            }
            HStack {
                Picker("Levels", selection: $levels) { Text("1").tag(1); Text("2").tag(2); Text("3").tag(3) }.fixedSize()
                Spacer()
                if warm.bottle == ref.bottle {
                    Button("Cancel") { warm.cancel() }
                } else {
                    Button("Prepare folder") { warm.start(year: ref.year, bottle: ref.bottle, folder: folder.trimmingCharacters(in: .whitespaces), depth: levels) }
                        .disabled(folder.trimmingCharacters(in: .whitespaces).isEmpty || warm.running)
                }
            }
            if warm.bottle == ref.bottle { HStack { ProgressView().controlSize(.small); Text(warm.line.isEmpty ? String(localized: "Listing…") : warm.line).font(.callout) } }
            else if warm.running { Text("Preparing a folder for another Revit.").font(.callout).foregroundStyle(.secondary) }
            else if !warm.line.isEmpty { Text(warm.line).font(.callout).foregroundStyle(warm.failed ? .red : .secondary).textSelection(.enabled) }
        }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { folder = u.path }
    }
}

private struct GoogleDriveTab: View {
    let app: AppModel
    let env: AppEnvironment
    let ref: BottleRef
    let bottle: Bottle
    @State private var draft = GDriveDraft(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(mapping, systemImage: "externaldrive").font(.headline)
            Text("Links to G:\\Shared drives\\… from Windows colleagues open.").font(.callout).foregroundStyle(.secondary)
            Picker("Account", selection: $draft.picked) {
                Text("Automatic").tag("auto"); Text("Account").tag("account"); Text("Off").tag("off")
            }
            .pickerStyle(.segmented).frame(maxWidth: 420)
            if draft.needsEmail {
                if draft.mode == "account" { Text("A chosen account. To change it, type another address.").font(.callout).foregroundStyle(.secondary) }
                TextField("Google account address", text: $draft.email).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    .textContentType(.emailAddress).autocorrectionDisabled()
            }
            if draft.showsNames { Toggle("Russian Windows folder names too", isOn: $draft.russian) }
            else { Text("Own folder names are set.").font(.callout).foregroundStyle(.secondary) }
            Text("Quit Revit first: Wine shows a changed drive only when it starts again.").font(.callout).foregroundStyle(.secondary)
            if bottle.gdrive?.mapping == "ok", let w = env.warm { Divider(); PrepareFolder(warm: w, ref: ref).padding(.bottom, 4); Divider() }
            HStack {
                Button("Stop background programs…") { stop() }.disabled(app.isBusy)
                Spacer()
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
                    .disabled(!draft.canApply(running: bottle.running, busy: app.isBusy))
            }
        }
        .task(id: bottle.gdrive) { draft = GDriveDraft(bottle.gdrive) }
    }

    private var mapping: String {
        guard let g = bottle.gdrive, g.mode != "off" else { return String(localized: "No G: in this bottle") }
        switch g.mapping {
        case "ok": return String(localized: "G: is your Google Drive")
        case "account-missing": return String(localized: "The Google Drive account of G: is not on this Mac")
        case "stale": return String(localized: "G: needs setting up again")
        default: return g.accounts == "zero" ? String(localized: "Google Drive is not on this Mac") : String(localized: "G: is not set up yet")
        }
    }

    private func apply() {
        let c = draft.changes
        draft.email = ""
        Task { await Confirm.start(app: app, env: env, .set(year: ref.year, bottle: ref.bottle, settings: c)) }
    }

    private func stop() {
        guard Confirm.ask(String(localized: "Stop what runs in Revit \(String(ref.year))?"),
                          String(localized: "If Revit has just started, it closes and unsaved work is lost."),
                          button: String(localized: "Stop"), destructive: true) else { return }
        Task { await Confirm.start(app: app, env: env, .stop(year: ref.year, bottle: ref.bottle)) }
    }
}

private struct MaintenanceTab: View {
    let app: AppModel
    let env: AppEnvironment
    let ref: BottleRef
    let bottle: Bottle
    @State private var health: DoctorReport?
    @State private var checking = false
    @State private var healthError: String?
    @State private var logStarted = false
    @State private var logError: String?

    private var points: [RestorePoint] { (app.status?.restorePoints ?? []).filter { $0.bottle == ref.bottle && $0.year == String(ref.year) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Health") {
                Text("Checks Revit, its bottle and this Mac. Changes nothing.").font(.callout).foregroundStyle(.secondary)
                Button(checking ? "Checking…" : "Check now") { check() }.disabled(checking)
                if let e = healthError { Text(e).foregroundStyle(.red) }
                if let h = health?.forApp {
                    if h.problems.isEmpty { Label("All checks passed", systemImage: "checkmark.circle").foregroundStyle(.green) }
                    HealthList(checks: h.problems)
                }
            }
            section("Logs and reports") {
                HStack {
                    Button("Show logs") { showLogs() }
                    Button(app.revitStarting[ref.bottle] != nil ? "Starting…" : "Start with a log") { startLog() }
                        .disabled(bottle.running || app.isBusy || app.revitStarting[ref.bottle] != nil)
                    Button("Report a problem…") { Task { await Report.copy(app: app, year: ref.year, bottle: ref.bottle, logDir: nil) } }
                }
                if logStarted { Text("Make the problem happen, quit Revit, then use Report a problem.").font(.callout) }
                if let e = logError { Text(e).font(.callout).foregroundStyle(.red) }
                Text("Reports leave out personal data.").font(.callout).foregroundStyle(.secondary)
            }
            section("Something wrong?") {
                HStack {
                    Text("Steps from the safest to the last resort.")
                    Spacer()
                    Button("Show the steps…") { env.router.recover(ref) }
                }
            }
            section("Fixes") {
                switch FixesLine.of(built: bottle.built, now: app.status?.shimsNow) {
                case .unknown: Text("Built with fixes: unknown.").foregroundStyle(.secondary)
                case .built(let v): Text("Built with fixes \(v).")
                case .newer(let v, let n): Text("Built with fixes \(v). A rebuild brings newer fixes (\(n)).")
                }
            }
            section("Restore points") {
                Text("A copy of the bottle from before a rebuild, with settings, add-ins and sign-in. Free at first; later up to the bottle's full size.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if points.isEmpty { Text("No restore points.").foregroundStyle(.secondary) }
                ForEach(points, id: \.id) { p in
                    HStack {
                        Text(PointTime.text(p.time))
                        Text("up to \(ByteCountFormatter().string(fromByteCount: p.bytes))").foregroundStyle(.secondary)
                        Spacer()
                        Button("Roll back…") { env.router.ask(.rollback(year: ref.year, bottle: ref.bottle, id: p.id)) }
                            .disabled(app.isBusy || bottle.running)
                    }
                }
                if points.count > 1 {
                    Button("Delete all but the newest…") { env.router.ask(.points(year: ref.year, bottle: ref.bottle, clear: "old")) }.disabled(app.isBusy)
                }
            }
            section("Update Revit") {
                HStack {
                    Text("Got a newer update from your Autodesk Account? Choose it; the rest is a rebuild with a restore point.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Choose installer…") { chooseInstaller() }.disabled(app.isBusy || bottle.running)
                }
            }
            section("Start over") {
                HStack {
                    Text("Rebuild: a fresh bottle, the newest fixes, a restore point first.")
                    Spacer()
                    Button("Rebuild…") { env.router.ask(.plan(.rebuild(year: ref.year, bottle: ref.bottle, source: nil))) }.disabled(app.isBusy)
                }
                HStack {
                    Text("Remove: Revit, its bottle, apps and restore points.")
                    Spacer()
                    Button("Remove…", role: .destructive) { env.router.ask(.plan(.remove(year: ref.year, bottle: ref.bottle))) }.disabled(app.isBusy)
                }
            }
        }
        .task(id: env.router.healthWanted) {
            if env.router.healthWanted { env.router.healthWanted = false; check() }
        }
    }

    private func section<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); content() }
    }

    private func chooseInstaller() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = false
        p.message = String(localized: "Choose the folder with the Revit \(String(ref.year)) installer.")
        if p.runModal() == .OK, let u = p.url {
            env.router.ask(.plan(.update(year: ref.year, bottle: ref.bottle, from: u.path)))
        }
    }

    private func startLog() {
        logStarted = false; logError = nil
        Task {
            switch await app.debug(year: ref.year, bottle: ref.bottle) {
            case .started: logStarted = true
            case .refused(let why): logError = why
            }
        }
    }

    private func check() {
        checking = true
        Task {
            defer { checking = false }
            guard let out = await app.query(["doctor", String(ref.year), ref.bottle, "--json"]) else { healthError = app.engineError; return }
            health = try? JSONDecoder.engine.decode(DoctorReport.self, from: out.stdout)   // a failed check is exit 1 with JSON
            healthError = health == nil ? out.stderr.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
    }

    private func showLogs() {
        guard let data = app.dataFolder else { return }
        let l = AppLinks.logs(data: data, bottle: ref.bottle)
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: l.path) ? l : AppLinks.logs(data: data, bottle: nil))
    }
}

/// doctor's checks: problems in red or orange with what to do, the rest as they are.
struct HealthList: View {
    let checks: [DoctorReport.Check]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(checks, id: \.id) { c in
                VStack(alignment: .leading, spacing: 1) {
                    Label(c.title, systemImage: symbol(c.status)).foregroundStyle(color(c.status))
                    if !c.detail.isEmpty { Text(c.detail).font(.caption).foregroundStyle(.secondary) }
                    if !c.fix.isEmpty, c.status == "fail" || c.status == "warn" {
                        Text(c.fix).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func symbol(_ s: String) -> String {
        switch s { case "fail": "xmark.circle"; case "warn": "exclamationmark.triangle"; case "ok": "checkmark.circle"; default: "info.circle" }
    }
    private func color(_ s: String) -> Color {
        switch s { case "fail": .red; case "warn": .orange; case "ok": .green; default: .secondary }
    }
}
