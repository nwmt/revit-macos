// One screen per kind of failure (spec §4), the engine's own text, and what can be done next: Retry (the engine
// resumes a download), the source choice, the wizard, Show log, Copy diagnostic report. Retry and the source buttons
// exist only for a run this app started.
import AppCore
import SwiftUI

/// Where a result's buttons lead. Activity: as always. A sheet: each closes the sheet first, and what it leads to comes
/// once the sheet is gone; a Retry that starts a run leads to Activity (the sheet follows only its own run).
struct ResultNav {
    let addins: (BottleRef) -> Void
    let addVersion: () -> Void
    let retry: (RunRequest) -> Void
    let close: () -> Void

    @MainActor static func activity(_ app: AppModel, _ env: AppEnvironment) -> ResultNav {
        ResultNav(addins: { env.router.open(.addins($0)) }, addVersion: { env.router.addVersion() },
                  retry: { retry($0, app, env) }, close: { app.dismissFailure() })
    }

    @MainActor static func sheet(_ app: AppModel, _ env: AppEnvironment) -> ResultNav {
        let r = env.router
        return ResultNav(addins: { ref in r.close { r.open(.addins(ref)) } }, addVersion: { r.close { r.addVersion() } },
                         retry: { req in r.close { retry(req, app, env); if SheetRequest.of(req, bottleExists: true) == nil { r.open(.run) } } },
                         close: { app.dismissFailure(); r.close() })
    }

    @MainActor private static func retry(_ r: RunRequest, _ app: AppModel, _ env: AppEnvironment) {
        if let s = SheetRequest.of(r, bottleExists: app.status?.bottles.contains { $0.name == r.bottle } ?? true) { env.router.ask(s); return }   // deletes something: a new plan, confirmed again
        app.dismissFailure()
        Task { await Confirm.start(app: app, env: env, r) }
    }
}

struct FailureView: View {
    let app: AppModel
    let env: AppEnvironment
    let run: WatchedRun
    let failure: Failure
    let nav: ResultNav

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
                Button("Set up CrossOver…") { nav.addVersion() }
            case .rosettaMissing:
                Text("Rosetta is not installed.").font(.headline)
                Button("Install Rosetta…") { nav.addVersion() }
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
                    Button("Choose add-ins…") { nav.addins(BottleRef(year: r.year, bottle: r.bottle)) }
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
                Button("Close") { nav.close() }
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

    private func retry(_ r: RunRequest) { nav.retry(r) }

    private func isRebuild(_ r: RunRequest) -> Bool { if case .rebuild = r { true } else { false } }
}
