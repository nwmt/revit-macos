// The first-run wizard and "Add Revit version…": a checklist of six rows; done rows are one line, the first open
// row is expanded. Every row's state comes from WizardModel.
import AppCore
import SwiftUI
import UniformTypeIdentifiers

struct WizardWindow: View {
    let app: AppModel
    let env: AppEnvironment
    var body: some View {
        if let w = env.wizard { WizardView(wizard: w, env: env) }
    }
}

struct WizardView: View {
    @Bindable var wizard: WizardModel
    let env: AppEnvironment
    @State private var pickFile = false
    @State private var pickFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(env.name) for Autodesk® Revit® on Apple Silicon Macs").font(.headline)
                Text("Not affiliated with or endorsed by Autodesk.").font(.caption).foregroundStyle(.secondary)
                Text("Autodesk and Revit are registered trademarks or trademarks of Autodesk, Inc., in the USA and other countries.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ForEach(WizardRow.allCases, id: \.self) { row in rowView(row) }
        }
        .padding(20)
        .frame(width: 560, alignment: .topLeading)
        .fileImporter(isPresented: $pickFile, allowedContentTypes: [.item]) { r in
            if case .success(let u) = r { Task { await wizard.importMsls31(u) } }
        }
        .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { r in
            if case .success(let u) = r { Task { await wizard.chooseInstaller(u) } }
        }
    }

    @ViewBuilder private func rowView(_ row: WizardRow) -> some View {
        let s = wizard.state(row)
        let expanded = wizard.firstOpen == row || { if case .failed = s { true } else { false } }() || { if case .warning = s { true } else { false } }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: symbol(s)).foregroundStyle(color(s))
                Text(title(row)).fontWeight(expanded ? .semibold : .regular)
                Spacer()
                Text(summary(s)).foregroundStyle(.secondary).lineLimit(2)
            }
            if expanded || row == .check || row == .install { controls(row, s) }
            if s == .waiting, (row == .check || row == .install), let b = wizard.busyText { Text("Busy: \(b)").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func controls(_ row: WizardRow, _ s: RowState) -> some View {
        switch row {
        case .rosetta:
            Text("Revit's installers need Rosetta. Installing it accepts Apple's license for Rosetta; macOS asks for your password.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Install Rosetta…") { Task { await wizard.installRosetta() } }.disabled(s == .working)
        case .crossover:
            Button("Install CrossOver…") { Task { await wizard.installCrossOver() } }.disabled(s == .working)
            if let n = wizard.crossoverNote { Text(n).font(.callout) }
        case .msls31:
            Text("Copy C:\\Windows\\System32\\msls31.dll from a licensed Windows 7/10 x64 PC, then drop it here.")
                .font(.callout).foregroundStyle(.secondary)
            dropZone(String(localized: "Drop msls31.dll here")) { u in Task { await wizard.importMsls31(u) } }
            Button("Choose file…") { pickFile = true }
        case .installer:
            Text("The folder with your Revit installer from your Autodesk Account (it is only read).").font(.callout).foregroundStyle(.secondary)
            dropZone(String(localized: "Drop the installer folder here")) { u in Task { await wizard.chooseInstaller(u) } }
            Button("Choose folder…") { pickFolder = true }
        case .check:
            if wizard.installer != nil {
                HStack {
                    Text("Bottle")
                    TextField("rvt2025-a", text: $wizard.bottleName).frame(width: 180)
                    Button("Check") { Task { await wizard.runCheck() } }.disabled(s == .working || s == .waiting)
                }
                ForEach(wizard.checkWarnings, id: \.self) { w in Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if wizard.offersSourceChoice {
                    HStack {
                        Button("Use the existing one") { Task { await wizard.choose(.reuseExtracted) } }
                        Button("Unpack again") { Task { await wizard.choose(.reextract) } }
                    }
                }
            }
        case .install:
            if s == .open {
                Button("Install") {
                    Task { if (try? await wizard.install()) != nil { env.router.open(.run) } }
                }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func dropZone(_ text: String, _ dropped: @escaping (URL) -> Void) -> some View {
        Text(text).frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.secondary))
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = urls.first else { return false }
                dropped(u); return true
            }
    }

    private func title(_ r: WizardRow) -> String {
        switch r {
        case .rosetta: String(localized: "Rosetta")
        case .crossover: String(localized: "CrossOver")
        case .msls31: String(localized: "msls31.dll")
        case .installer: String(localized: "Revit installer")
        case .check: String(localized: "Check")
        case .install: String(localized: "Install")
        }
    }

    private func summary(_ s: RowState) -> String {
        switch s {
        case .done(let t), .warning(let t), .failed(let t): t
        case .working: String(localized: "Working…")
        case .open, .waiting: ""
        }
    }

    private func symbol(_ s: RowState) -> String {
        switch s {
        case .done: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .open: "circle"
        case .waiting: "circle.dotted"
        case .working: "arrow.triangle.2.circlepath"
        case .failed: "xmark.circle.fill"
        }
    }

    private func color(_ s: RowState) -> Color {
        switch s {
        case .done: .green
        case .warning: .orange
        case .failed: .red
        default: .secondary
        }
    }
}
