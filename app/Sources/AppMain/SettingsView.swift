// Settings: open at login, the daily update check, the installer files that can be deleted, About.
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
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $settings.launchAtLogin)
                if let n = settings.loginNote { Text(n).font(.callout).foregroundStyle(.secondary) }
                if let e = settings.loginError { Text(e).font(.callout).foregroundStyle(.red) }
                Toggle("Check for updates once a day", isOn: $settings.checkForUpdates)
            }
            if let t = env.trackpad { TrackpadSection(model: t) }
            if let b = app.status?.bottles.first(where: { $0.steel == "on" }) {
                Section("Models with links") {
                    Text("They wait 1 to 3 minutes on first open: Steel Connections looks for a database the bottle does not have. Turning it off removes the steel connection tools.")
                        .font(.callout)
                    Text("./revit set \(b.year) \(b.name) steel=off").font(.callout.monospaced()).textSelection(.enabled)
                }
            }
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
                    Button("Delete…", role: .destructive) { delete() }.disabled(c.removableBytes == 0 || app.isBusy)
                }
                if let e = settings.cacheError { Text(e).font(.callout).foregroundStyle(.red) }
            }
            Section("About") {
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
        .formStyle(.grouped)
        .frame(width: 520)
        .task { await settings.loadCache() }
    }

    private func delete() {
        guard Confirm.ask(String(localized: "Delete the installer files?"), String(localized: "A later install or rebuild downloads them again."),
                          button: String(localized: "Delete"), destructive: true) else { return }
        Task { await settings.clearCache() }
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
