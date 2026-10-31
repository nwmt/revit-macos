// Activity: the runs of the app, the one that goes on and those before it, and the programs left running.
import AppCore
import SwiftUI

struct ActivityView: View {
    let app: AppModel
    let env: AppEnvironment
    @State private var rows: [RunRow] = []
    @State private var selected: String?

    private var runs: URL? { app.dataFolder?.appending(path: "logs/runs") }
    private var phase: RunPhase? { app.watched?.phase }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                List(rows, selection: $selected) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle().fill(color(r.outcome)).frame(width: 8, height: 8)
                            Text(r.title).lineLimit(1)
                        }
                        Text("\(r.bottle) · \(r.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(r.id)
                }
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                ScrollView {
                    detail.padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minWidth: 340)
            }
            Divider()
            ProgramsLeft(app: app).padding(16)
        }
        .navigationTitle("Activity")
        .onAppear { reload() }
        .onChange(of: phase) { reload() }
        .onChange(of: app.watched?.ctx) { reload() }
    }

    @ViewBuilder private var detail: some View {
        if let r = rows.first(where: { $0.id == selected }), r.ctx.lastPathComponent != app.watched?.ctx.lastPathComponent {
            PastRun(app: app, row: r)
        } else if app.watched != nil || app.busyText != nil {
            RunWindow(app: app, env: env)
        } else if rows.isEmpty {
            Text("Nothing has run yet.").foregroundStyle(.secondary)
        } else {
            Text("Choose a task.").foregroundStyle(.secondary)
        }
    }

    private func reload() {
        guard let runs else { return }
        rows = ActivityLog.load(runs: runs, active: phase == .running || phase == .finishing ? app.watched?.ctx : nil)
        if phase == .running || selected == nil { selected = rows.first?.id }   // a task that starts comes to the front
    }

    private func color(_ o: RunRow.Outcome) -> Color {
        switch o {
        case .running: .accentColor
        case .done: .green
        case .partial, .stopped, .interrupted: .orange
        case .failed: .red
        }
    }
}

private struct PastRun: View {
    let app: AppModel
    let row: RunRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.bottle.isEmpty ? row.title : "\(row.title) · \(row.bottle)").font(.headline)
            Text(words).foregroundStyle(.secondary)
            ForEach(row.state.steps, id: \.id) { s in
                HStack(spacing: 8) {
                    Text(s.id).font(.system(.body, design: .monospaced))
                    Text(s.state).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(row.state.messages.enumerated()), id: \.offset) { _, m in
                Text(m.text).foregroundStyle(m.level == "error" ? .red : .secondary).textSelection(.enabled)
            }
            if let log = row.state.end?.logDir, !log.isEmpty, FileManager.default.fileExists(atPath: log) {
                Button("Show log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
            }
        }
    }

    private var words: String {
        switch row.outcome {
        case .running: String(localized: "Running")
        case .done: String(localized: "Done")
        case .partial: String(localized: "Done, but some steps failed.")
        case .failed: String(localized: "Failed")
        case .stopped: String(localized: "Stopped")
        case .interrupted: String(localized: "Interrupted")
        }
    }
}

private struct ProgramsLeft: View {
    let app: AppModel
    @State private var report: CleanupReport?
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Programs left running").font(.headline)
                Spacer()
                Button("Close these") { close() }.disabled((report?.items ?? []).isEmpty || app.isBusy)
                Button("Close all of Wine…") { Task { await Confirm.closeAll(app: app); await load() } }.disabled(app.isBusy)
            }
            if let items = report?.items, !items.isEmpty {
                ForEach(items, id: \.target) { Text($0.line).font(.system(.callout, design: .monospaced)).lineLimit(1) }
            } else { Text("None.").foregroundStyle(.secondary) }
            Text("Bottles where Revit still runs are left alone. Close all of Wine quits Revit too, without saving.").font(.caption).foregroundStyle(.secondary)
            if let note { Text(note).font(.caption).foregroundStyle(.orange) }
        }
        .task { await load() }
    }

    private func load() async {
        if case let .report(r) = await app.cleanup(all: false, dryRun: true) { report = r }
    }

    private func close() {
        let items = report?.items ?? []
        Task {
            switch await app.cleanup(all: false, dryRun: false, targets: items) {
            case let .refused(t): note = t
            case let .report(r): note = (r.left ?? []).isEmpty ? nil : String(localized: "\(r.left?.count ?? 0) program(s) could not be ended. Restart the Mac to end them.")
            }
            await load()
        }
    }
}
