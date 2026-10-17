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
                    .font(.caption).foregroundStyle(.secondary)
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
