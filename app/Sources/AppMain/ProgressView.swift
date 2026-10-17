// The progress window ("run"): the run's actions and steps, the download, the engine's messages, Cancel; at the end
// the result. Closing it changes nothing: the run goes on.
import AppCore
import SwiftUI

struct RunWindow: View {
    let app: AppModel
    let env: AppEnvironment
    @State private var refusal: String?
    @State private var cancelling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let w = app.watched {
                let m = MenuContent.make(status: app.status, watched: w, failure: app.failure, busy: app.isBusy)
                Text(header(w, m)).font(.headline)
                if !w.state.actions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(w.state.actions, id: \.id) { a in Label(ActionWords.of(a.id), systemImage: symbol(a.state)) }
                    }
                }
                if let p = w.state.downloadPercent, w.state.currentAction == "revit" {
                    ProgressView(value: Double(p), total: 100) { Text("Downloading Revit: \(p)%") }
                }
                if !w.state.steps.isEmpty {
                    GroupBox("Steps") {
                        ScrollViewReader { proxy in ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(w.state.steps, id: \.id) { s in
                                    Label {
                                        HStack(spacing: 8) {
                                            Text(s.id).font(.system(.body, design: .monospaced))
                                            if let d = s.detail { Text(d).foregroundStyle(.secondary) }
                                        }
                                    } icon: { Image(systemName: symbol(s.state)) }
                                    .lineLimit(1).id(s.id)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // a fixed height: a window sized to its content gives a bare ScrollView none at all
                        .frame(height: min(CGFloat(w.state.steps.count) * 22 + 6, 200))
                        .onChange(of: w.state.steps.count) { proxy.scrollTo(w.state.steps.last?.id, anchor: .bottom) } }
                    }
                }
                ForEach(Array(w.state.messages.enumerated()), id: \.offset) { _, msg in
                    Label(msg.text, systemImage: msg.level == "error" ? "xmark.octagon" : "exclamationmark.triangle")
                        .foregroundStyle(msg.level == "error" ? .red : .orange).textSelection(.enabled)
                }
                if w.phase == .running || w.phase == .finishing {
                    HStack {
                        if w.phase == .finishing { Text("Finishing…").foregroundStyle(.secondary) }
                        Spacer()
                        if m.activity?.cancellable == true {
                            Button("Cancel") { cancel() }.disabled(cancelling)
                        }
                    }
                    if let refusal { Text(refusal).foregroundStyle(.secondary) }
                } else {
                    Divider()
                    ResultView(app: app, env: env, run: w)
                }
            } else if let b = app.busyText {
                Text("Busy: \(b)")
            } else {
                Text("Nothing is running.").foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 520, alignment: .topLeading)
    }

    private func header(_ w: WatchedRun, _ m: MenuContent) -> String {
        let y = (w.state.year ?? w.record?.request.year).map(String.init) ?? ""
        let verb = MenuContent.verb(w.state.command ?? w.record?.request.arguments.first ?? "", y)
        let bottle = w.state.bottle ?? w.record?.request.bottle ?? ""
        return bottle.isEmpty ? verb : "\(verb) · \(bottle)"
    }

    private func symbol(_ state: String) -> String {
        switch state {
        case "done": "checkmark.circle.fill"
        case "running": "arrow.triangle.2.circlepath"
        case "skipped": "minus.circle"
        case "failed": "xmark.circle.fill"
        default: "circle"
        }
    }

    private func cancel() {
        cancelling = true
        Task {
            if case .refused(let why) = await app.cancel() { refusal = why } else { refusal = nil }
            cancelling = false
        }
    }
}

/// The engine's action ids in words (the same words as the menu).
enum ActionWords {
    static func of(_ id: String) -> String {
        var s = RunState(); s.apply(.action(id: id, state: "running", exit: nil))
        return MenuContent.doing(s) ?? id
    }
}

/// The end of a run: success with its next steps, or the failure.
struct ResultView: View {
    let app: AppModel
    let env: AppEnvironment
    let run: WatchedRun

    var body: some View {
        if run.succeeded {
            let kind = run.state.end?.kind
            VStack(alignment: .leading, spacing: 8) {
                Text(kind == .stopped ? "Stopped." : "Done.").font(.headline)
                if kind == .ok, let r = run.record?.request, isInstall(r) {
                    HStack {
                        Button("Open Revit") {
                            NSWorkspace.shared.open(AppLinks.revitApp(year: r.year, bottle: r.bottle, home: FileManager.default.homeDirectoryForCurrentUser))
                        }
                        Button("Choose add-ins…") { env.router.open(.addins(BottleRef(year: r.year, bottle: r.bottle))) }
                    }
                }
            }
        } else if let f = app.failure {
            FailureView(app: app, env: env, run: run, failure: f)
        } else {
            Text("The task did not end well. Its log has the details.").foregroundStyle(.secondary)   // details closed
        }
    }
}

func isInstall(_ r: RunRequest) -> Bool {
    switch r { case .install, .rebuild: true; default: false }
}
