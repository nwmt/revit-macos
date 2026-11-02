// Settings in tabs: General (the Dock, open at login, updates, Check this Mac), Trackpad, Storage (installer files and
// the restore points of every bottle, removed ones too), About.
import AppCore
import SwiftUI

struct SettingsWindow: View {
    let app: AppModel
    let env: AppEnvironment
    var body: some View {
        if let s = env.settings { SettingsView(settings: s, app: app, env: env) }
    }
}

struct SettingsView: View {
    @Bindable var settings: SettingsModel
    let app: AppModel
    let env: AppEnvironment
    @State private var points: SheetRequest?
    @State private var checkingMac = false
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { form { general } }
            if let t = env.trackpad { Tab("Trackpad", systemImage: "hand.draw") { form { TrackpadSection(model: t) } } }
            Tab("Storage", systemImage: "internaldrive") { form { storage } }
            Tab("About", systemImage: "info.circle") { form { about } }
        }
        .frame(width: 560)
        .task { await settings.loadCache() }
        // the plan of a deletion: the engine's dry run, as on a version's page; the run then shows in Activity
        .sheet(item: $points) { PlanSheet(app: app, env: env, request: $0) }
        .sheet(isPresented: $checkingMac) { MacCheckSheet(app: app) }
    }

    private func form<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        Form { c() }.formStyle(.grouped).frame(minHeight: 380)
    }

    @ViewBuilder private var general: some View {
        Section {
            Picker("Show \(env.name) in", selection: Binding(get: { settings.showInDock }, set: { settings.showInDock = $0; env.dockChoiceChanged() })) {
                Text("The Dock and the menu bar").tag(true)
                Text("The menu bar only").tag(false)
            }
            .pickerStyle(.radioGroup)
            Toggle("Open at login", isOn: $settings.launchAtLogin)
            if let n = settings.loginNote { Text(n).font(.callout).foregroundStyle(.secondary) }
            if let e = settings.loginError { Text(e).font(.callout).foregroundStyle(.red) }
            Toggle("Check for updates once a day", isOn: $settings.checkForUpdates)
        }
        Section {
            HStack {
                Text("Check this Mac: CrossOver, Rosetta, disk. Changes nothing.")
                Spacer()
                Button("Check") { checkingMac = true }
            }
        }
    }

    @ViewBuilder private var storage: some View {
        Section("Installer files") {
            if let c = settings.cache {
                Text(c.removableBytes > 0 ? "\(ByteCountFormatter().string(fromByteCount: c.removableBytes)) can be deleted" : "Nothing to delete")
                ForEach(c.items, id: \.label) { i in
                    HStack {
                        Text(i.label)
                        Spacer()
                        Text(i.removable ? ByteCountFormatter().string(fromByteCount: i.bytes) : String(localized: "kept: \(i.kept)"))
                            .foregroundStyle(.secondary)
                    }.font(.callout)
                }
                Text("A later install or rebuild downloads them again.").font(.caption).foregroundStyle(.secondary)
                Button("Delete…", role: .destructive) { delete() }.disabled(c.removableBytes == 0 || app.isBusy)
            }
            if let e = settings.cacheError { Text(e).font(.callout).foregroundStyle(.red) }
        }
        Section("Restore points") {
            let c = StorageContent.make(app.status)
            Text("Each holds up to its bottle's full size once the bottle changes.").font(.caption).foregroundStyle(.secondary)
            if c.points.isEmpty && c.leftoversOnly.isEmpty { Text("No restore points.").foregroundStyle(.secondary) }
            ForEach(Array(c.points.enumerated()), id: \.offset) { _, p in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(p.bottle) · Revit \(String(p.year))\(p.removed ? String(localized: " (removed)") : "")")
                        Text(pointLine(p)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let clear = p.clear {
                        Button(p.action == .keepNewest ? "Keep newest…" : "Delete…", role: p.action == .deleteAll ? .destructive : nil) {
                            points = .points(year: p.year, bottle: p.bottle, clear: clear)
                        }.disabled(app.isBusy)
                    }
                }
            }
            ForEach(c.leftoversOnly, id: \.self) { b in
                VStack(alignment: .leading, spacing: 2) {
                    Text(b)
                    Text("Files of a restore point cut short. Delete them in Finder: Revit Restore Points, beside the Bottles folder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pointLine(_ p: PointRow) -> String {
        let n = p.count == 1 ? String(localized: "1 point") : String(localized: "\(p.count) points")
        var s = "\(n), " + String(localized: "up to \(ByteCountFormatter().string(fromByteCount: p.bytes))")
        if p.unfinished { s += ", " + String(localized: "unfinished files") }
        return s
    }

    @ViewBuilder private var about: some View {
        Section {
            Text("\(env.name) \(version)").font(.headline)
            Text("for Autodesk® Revit® on Apple Silicon Macs")
            Text("Not affiliated with or endorsed by Autodesk.").font(.caption).foregroundStyle(.secondary)
            Text("Autodesk and Revit are registered trademarks or trademarks of Autodesk, Inc., in the USA and other countries.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if !env.repo.isEmpty, let u = URL(string: "https://github.com/\(env.repo)") { Link("Project page", destination: u) }
                Button("Licenses") {
                    if let r = Bundle.main.resourceURL { NSWorkspace.shared.open(r.appending(path: "Licenses")) }
                }
            }
        }
    }

    private func delete() {
        guard Confirm.ask(String(localized: "Delete the installer files?"), String(localized: "A later install or rebuild downloads them again."),
                          button: String(localized: "Delete"), destructive: true) else { return }
        Task { await settings.clearCache() }
    }
}

/// Check this Mac: doctor without a year (this Mac, CrossOver, the bottles). Changes nothing.
struct MacCheckSheet: View {
    let app: AppModel
    @State private var report: DoctorReport?
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check this Mac").font(.title3.bold())
            if let r = report {
                let bad = r.problems.count
                Label(bad == 0 ? String(localized: "No problems") : bad == 1 ? String(localized: "1 problem") : String(localized: "\(bad) problems"),
                      systemImage: bad == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(bad == 0 ? .green : .orange)
                ScrollView { HealthList(checks: r.checks).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 360)
            } else if let p = problem {
                Text(p.isEmpty ? String(localized: "Could not check this Mac.") : p).foregroundStyle(.red).textSelection(.enabled)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 520, alignment: .topLeading)
        .task {
            guard let out = await app.query(["doctor", "--json"]) else { problem = app.engineError ?? ""; return }
            // a failed check is exit 1 with the JSON
            if let r = try? JSONDecoder.engine.decode(DoctorReport.self, from: out.stdout) { report = r.forApp }
            else { problem = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
}

/// Trackpad in Revit: the switch, one status line, the button that line needs.
struct TrackpadSection: View {
    let model: TrackpadModel
    private let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    var body: some View {
        Section("Trackpad in Revit") {
            Toggle("Pan, orbit and zoom with the trackpad", isOn: Binding(get: { model.enabled },
                                                                         set: { on in Task { await model.setEnabled(on) } }))
                .disabled(model.line == .notInApplications)
            Text("In Revit's views, two fingers pan, Shift and two fingers orbit, a pinch zooms. Elsewhere scrolling stays scrolling.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch model.line {
            case .off: EmptyView()
            case .starting: Text("Starting…").font(.callout)
            case .on: Text("On").font(.callout)
            case .waiting(let section):
                Text("Waiting for permission: System Settings → Privacy & Security → \(section) → turn on the trackpad helper.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { NSWorkspace.shared.open(settingsURL) }
            case .lost:
                Text("macOS no longer accepts the earlier permission (the helper changed).").font(.callout)
                Button("Ask again") { Task { await model.askAgain() } }
            case .lostManual:
                Text("In System Settings → Privacy & Security → \(TrackpadModel.section), remove the trackpad helper with −, then turn this switch off and on.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { NSWorkspace.shared.open(settingsURL) }
            case .error(let e): Text("Not working: \(e)").font(.callout).foregroundStyle(.red)
            case .notInApplications: Text("Works only for the app in the Applications folder.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .task {
            while !Task.isCancelled { model.refresh(); try? await Task.sleep(for: .seconds(1)) }
        }
    }
}
