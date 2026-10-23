// The add-ins window of one bottle: the catalog for its year with checkboxes for what can be added, the file an add-in
// needs from the user, the license to accept, Ghostscript, "Install selected"; then the run, as the progress window.
import AppCore
import SwiftUI

struct AddinsWindow: View {
    let app: AppModel
    let env: AppEnvironment
    let ref: BottleRef
    @State private var model: AddinsModel?

    var body: some View {
        Group {
            if let model { AddinsView(model: model, app: app, env: env) } else { ProgressView().padding() }
        }
        .task(id: ref) {
            let m = AddinsModel(app: app, system: MacSystemActions(), year: ref.year, bottle: ref.bottle)
            model = m
            await m.load()
        }
    }
}

struct AddinsView: View {
    let model: AddinsModel
    let app: AppModel
    let env: AppEnvironment
    @State private var license: (id: String, url: String)?
    @State private var importFor: String?

    private var myRun: Bool {
        guard let r = app.watched?.record?.request, case .addins(let y, let b, _, _) = r else { return false }
        return y == model.year && b == model.bottle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add-ins of Revit \(String(model.year)) · \(model.bottle)").font(.headline)
            ForEach(model.rows, id: \.id) { r in row(r) }
            if model.rows.isEmpty { Text("No add-ins for Revit \(String(model.year)).").foregroundStyle(.secondary) }
            if let e = model.error { Text(e).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Install selected") {
                    Task {
                        do { try await model.installSelected() } catch { Confirm.tell(String(localized: "Another task is running."), app.busyText ?? "") }
                    }
                }
                .disabled(model.selected.isEmpty || app.isBusy || model.working)
                .keyboardShortcut(.defaultAction)
            }
            if myRun { Divider(); RunWindow(app: app, env: env) }
        }
        .padding(20)
        .frame(width: 560, alignment: .topLeading)
        .sheet(isPresented: Binding(get: { license != nil }, set: { if !$0 { license = nil } })) {
            if let l = license {
                VStack(alignment: .leading, spacing: 12) {
                    Text("This add-in has its own license.").font(.headline)
                    if let n = model.rows.first(where: { $0.id == l.id })?.notice, !n.isEmpty {
                        Text(n).fixedSize(horizontal: false, vertical: true)
                    }
                    if let u = URL(string: l.url) { Link(l.url, destination: u) }
                    Text("Installing it means you accept that license.").foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Cancel") { license = nil }
                        Button("I accept") { model.accept(l.id); license = nil }.keyboardShortcut(.defaultAction)
                    }
                }
                .padding(20).frame(width: 420)
            }
        }
        .fileImporter(isPresented: Binding(get: { importFor != nil }, set: { if !$0 { importFor = nil } }), allowedContentTypes: [.item]) { r in
            if case .success(let u) = r, let id = importFor { Task { await model.importFile(id, u) } }
            importFor = nil
        }
    }

    @ViewBuilder private func row(_ r: AddinRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            switch r.state {
            case .available:
                Toggle(isOn: Binding(get: { model.selected.contains(r.id) }, set: { _ in
                    if let url = model.toggle(r.id) { license = (r.id, url) }
                })) { title(r) }
            case .installed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); title(r)
                Spacer(); Text("installed").foregroundStyle(.secondary)
            case .needsFile:
                Image(systemName: "doc.badge.plus").foregroundStyle(.secondary); title(r)
                Spacer(); Button("Choose file…") { importFor = r.id }.disabled(model.working)
            case .needsTool(let brew):
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(.secondary); title(r)
                Spacer()
                if brew { Button("Install Ghostscript") { Task { await model.installTool(r.id) } }.disabled(model.working) }
                else { Text("Needs Ghostscript: install Homebrew (brew.sh), then come back.").font(.callout).foregroundStyle(.secondary) }
            }
        }
    }

    private func title(_ r: AddinRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(r.name)
            Text(r.tested ? "\(r.about) · tested on Revit \(String(model.year))" : r.about).font(.caption).foregroundStyle(.secondary)
        }
    }
}
