// Confirmations of the actions that delete or end something (spec §3; the engine says what goes):
// Remove and Rebuild show the engine's dry-run plan with a red button; Force quit warns about unsaved work; Close all
// lists what it ends.
import AppCore
import AppKit

@MainActor enum Confirm {
    /// A modal alert; true when the user pressed the button.
    static func ask(_ title: String, _ text: String, button: String, destructive: Bool) -> Bool {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        let b = a.addButton(withTitle: button); b.hasDestructiveAction = destructive
        a.addButton(withTitle: String(localized: "Cancel"))
        return a.runModal() == .alertFirstButtonReturn
    }

    static func tell(_ title: String, _ text: String) {
        NSApp.activate()
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        a.runModal()
    }

    /// Remove or Rebuild: the engine's --dry-run --json plan, then the run on a yes.
    static func plan(app: AppModel, env: AppEnvironment, _ r: RunRequest) async {
        let verb = r.arguments[0]
        guard let out = await app.query([verb, String(r.year), r.bottle, "--dry-run", "--json"]) else {
            tell(String(localized: "The engine could not be started."), app.engineError ?? ""); return
        }
        guard out.exitCode == 0, let p = try? JSONDecoder.engine.decode(RemovePlan.self, from: out.stdout) else {
            tell(String(localized: "Revit \(String(r.year)) (\(r.bottle))"), out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)); return
        }
        if p.nothing == true { tell(String(localized: "Nothing to remove for Revit \(String(r.year)) (\(r.bottle))."), ""); return }
        let size = ByteCountFormatter()
        var lines = [String(localized: "This deletes:")]
        lines += p.delete.map { i in i.bytes.map { "  \(i.label)  \(size.string(fromByteCount: $0))" } ?? "  \(i.label)" }
        for k in p.kept ?? [] { lines.append(String(localized: "Kept: \(k)")) }
        if p.addinsReset == true { lines.append(String(localized: "Revit settings and add-ins in this bottle are reset.")) }
        lines += p.notes
        let title = verb == "remove" ? String(localized: "Remove Revit \(String(r.year)) (\(r.bottle))?") : String(localized: "Rebuild Revit \(String(r.year)) (\(r.bottle))?")
        let button = verb == "remove" ? String(localized: "Remove") : String(localized: "Rebuild")
        guard ask(title, lines.joined(separator: "\n"), button: button, destructive: true) else { return }
        await start(app: app, env: env, r.withPlan(restorePoint: p.restorePoint))
    }

    /// Close all: what cleanup --all would end (all of Wine, Revit too, and what the app left), then the close on a yes:
    /// only what was shown, so a program that started since stays.
    static func closeAll(app: AppModel) async {
        let p: CleanupReport
        switch await app.cleanup(all: true, dryRun: true) {
        case let .refused(t): tell(String(localized: "Could not close the programs."), t); return
        case let .report(r): p = r
        }
        guard !p.items.isEmpty else {
            tell(String(localized: "Nothing to close."), p.planLines.joined(separator: "\n")); return
        }
        guard ask(String(localized: "Close \(p.items.count) program(s)?"), p.planLines.joined(separator: "\n"),
                  button: String(localized: "Close all"), destructive: true) else { return }
        switch await app.cleanup(all: true, dryRun: false, targets: p.items) {   // what was shown, nothing found since
        case let .refused(t): tell(String(localized: "Could not close the programs."), t)
        case let .report(r):
            let left = r.left ?? []
            if left.isEmpty { tell(String(localized: "Closed \(r.closed?.count ?? 0) program(s)."), "") }
            else { tell(String(localized: "\(left.count) program(s) could not be ended."), String(localized: "Restart the Mac to end them.")) }
        }
        await app.refresh()
    }

    /// Starts a run and shows its progress; a refusal (busy) or a start error says why.
    static func start(app: AppModel, env: AppEnvironment, _ r: RunRequest) async {
        do {
            try await app.start(r)
            env.router.open(.run)
        } catch AppModelError.busy {
            tell(String(localized: "Another task is running."), app.busyText ?? "")
        } catch {
            tell(String(localized: "The engine could not be started."), app.engineError ?? "\(error)")
        }
    }
}
