// One screen per kind of failure (spec §4), the engine's own text, and what can be done next: Retry (the engine
// resumes a download), the source choice, the wizard, Show log, Copy diagnostic report. Retry and the source buttons
// exist only for a run this app started.
import AppCore
import SwiftUI

struct FailureView: View {
    let app: AppModel
    let env: AppEnvironment
    let run: WatchedRun
    let failure: Failure
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch failure {
            case .busy(let owner):
                Text("Another task is running.").font(.headline)
                if !owner.isEmpty { Text(owner).font(.system(.body, design: .monospaced)) }
            case .noSpace(let log):
                Text("Not enough disk space.").font(.headline)
                Text("Free some space on the disk, then try again.")
                actions(log: log, retry: true)
            case .downloadBroken(let log):
                Text("The download broke off.").font(.headline)
                Text("Check the internet connection. Retry goes on from where it stopped.")
                actions(log: log, retry: true)
            case .crossoverMissing:
                Text("CrossOver is missing or not the tested version.").font(.headline)
                Button("Set up CrossOver…") { env.router.open(.wizard) }
            case .rosettaMissing:
                Text("Rosetta is not installed.").font(.headline)
                Button("Install Rosetta…") { env.router.open(.wizard) }
            case .sourceMismatch(let text):
                Text("The unpacked Revit is from another installer.").font(.headline)
                engineText(text)
                if let r = app.retryRequest {
                    HStack {
                        Button("Use the existing one") { retry(r.with(.reuseExtracted)) }
                        Button("Unpack again") { retry(r.with(.reextract)) }
                    }
                } else { elsewhere }
            case .inUse(let text):
                Text("The unpacked Revit is in use.").font(.headline)
                engineText(text)
            case .partial(let steps, let log, let downloadFailed):
                Text("Done, but some steps failed.").font(.headline)
                Text("Revit may still work. Failed: \(steps.joined(separator: ", "))")
                if let r = app.retryRequest, isInstall(r) {
                    Button("Choose add-ins…") { env.router.open(.addins(BottleRef(year: r.year, bottle: r.bottle))) }
                }
                actions(log: log, retry: downloadFailed)
            case .failed(let at, let text, let log):
                Text(at.isEmpty ? "The task failed." : "Failed at: \(ActionWords.of(at))").font(.headline)
                engineText(text)
                actions(log: log, retry: false)
            case .interrupted(let log):
                Text("The task was interrupted.").font(.headline)
                Text("It ended before it could say how. Start it again; the log may say where it stopped.")
                actions(log: log, retry: app.retryRequest != nil)
            case .usage(let text):
                Text("The engine refused the request.").font(.headline)
                engineText(text)
            }
            HStack {
                Spacer()
                Button("Copy diagnostic report") {
                    Task { await Report.copy(app: app, year: run.state.year ?? run.record?.request.year, bottle: run.state.bottle ?? run.record?.request.bottle, logDir: logDir) }
                }
                Button("Close") { app.dismissFailure(); dismissWindow(id: Route.run.id) }
            }
        }
        .textSelection(.enabled)
    }

    private var logDir: String? {
        switch failure {
        case .noSpace(let l), .downloadBroken(let l), .interrupted(let l): l
        case .partial(_, let l, _), .failed(_, _, let l): l
        default: run.state.end?.logDir
        }
    }

    private func engineText(_ t: String) -> some View {
        Text(t.isEmpty ? String(localized: "The engine gave no details; the log has them.") : t)
            .font(.system(.callout, design: .monospaced))
    }

    @ViewBuilder private var elsewhere: some View {
        Text("This task was started outside the app: run it again where it was started.").foregroundStyle(.secondary)
    }

    @ViewBuilder private func actions(log: String, retry: Bool) -> some View {
        HStack {
            Button("Show log") { showLog(log) }
            if retry {
                if let r = app.recoveryRequest { Button(isRebuild(r) ? String(localized: "Rebuild…") : String(localized: "Retry")) { self.retry(r) } } else { elsewhere }
            }
        }
    }

    private func showLog(_ log: String) {
        if !log.isEmpty, FileManager.default.fileExists(atPath: log) { NSWorkspace.shared.open(URL(fileURLWithPath: log)); return }
        if let d = app.dataFolder { NSWorkspace.shared.open(AppLinks.logs(data: d, bottle: run.state.bottle)) }
    }

    private func retry(_ r: RunRequest) {
        if isRebuild(r) { Task { await Confirm.plan(app: app, env: env, r) }; return }   // deletes the bottle: confirm first
        app.dismissFailure()
        Task { await Confirm.start(app: app, env: env, r) }
    }

    private func isRebuild(_ r: RunRequest) -> Bool { if case .rebuild = r { true } else { false } }
}
