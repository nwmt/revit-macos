// Confirmations of the actions that delete or end something (the engine says what goes): Remove, Rebuild, Roll back and
// deleting restore points are a sheet with the engine's dry-run plan; Force quit warns about unsaved work; Close all
// lists what it ends.
import AppCore
import AppKit
import SwiftUI

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

/// What the engine says will happen. The sheet keeps the one it showed: the button reads a new one, and any difference
/// stops there and asks again (PlanCheck).
enum LoadedPlan: Equatable {
    case bottle(RemovePlan), rollback(RollbackPlan), points(PointsPlan)

    var fingerprint: [String] {
        switch self {
        case .bottle(let p): p.fingerprint
        case .rollback(let p): p.fingerprint
        case .points(let p): p.fingerprint
        }
    }
}

struct PlanSheet: View {
    let app: AppModel
    let env: AppEnvironment
    let request: SheetRequest
    @State private var plan: LoadedPlan?
    @State private var problem: String?
    @State private var gate = SheetGate(year: nil)
    @State private var keepPoint = true
    @State private var changed = false
    @State private var working = false
    @State private var going: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    private var year: Int { switch request { case .plan(let r): r.year; case .rollback(let y, _, _), .points(let y, _, _): y } }
    private var bottle: String { switch request { case .plan(let r): r.bottle; case .rollback(_, let b, _), .points(_, let b, _): b } }
    private var isRebuild: Bool {
        switch request { case .plan(.rebuild), .plan(.update): true; default: false }
    }
    private var blocked: Bool { if case .bottle(let p)? = plan, let b = p.blocked, !b.isEmpty { true } else { false } }
    private var pointPossible: Bool { if case .bottle(let p)? = plan { p.restorePoint == true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
            if changed { Label("What this does has changed. Read it and confirm again.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            switch plan {
            case .bottle(let p)?: bottlePlan(p)
            case .rollback(let p)?:
                Text("Brings bottle \(p.bottle) back as it was at \(PointTime.text(p.time)).")
                if p.bottleExists { Text("Everything in the bottle's C: drive that changed since then is deleted.").foregroundStyle(.orange) }
                Text("The restore point stays.").foregroundStyle(.secondary)
            case .points(let p)?:
                Text("Deleted").font(.headline)
                lines(p.delete, upTo: true)
                if p.unfinished { Text("Files of a run that was cut short").font(.callout) }
            case nil: if problem == nil { ProgressView() }
            }
            if gate.year != nil, plan != nil {
                TextField("Type \(String(year)) to go on", text: $gate.typed).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { going?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(goWord) { go() }.keyboardShortcut(.defaultAction).tint(destructive ? .red : .accentColor)
                    .disabled(plan == nil || blocked || !gate.open || working || app.isBusy)
            }
        }
        .padding(20).frame(width: 520, alignment: .topLeading)
        .task { plan = await read(); reset() }
        .onDisappear { going?.cancel() }   // however the sheet closes, a Go still reading its plan stops there
    }

    @ViewBuilder private func updateLines(_ p: RemovePlan) -> some View {
        if let b = p.blocked, !b.isEmpty {
            Text(b).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Revit \(p.buildNow.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "(unknown)")) → \(p.buildNew.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "(unknown)"))").font(.headline)
            if p.newer == false { Text("This installer is not newer than the Revit in this bottle.").foregroundStyle(.orange) }
            if p.newer == nil { Text("The version could not be read.").font(.callout).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func bottlePlan(_ p: RemovePlan) -> some View {
        if case .plan(.update) = request { updateLines(p) }
        if isRebuild {
            Toggle("Keep a restore point", isOn: $keepPoint).disabled(!pointPossible)
            Text(keepPoint && pointPossible
                 ? "A copy of \(p.bottle) with its settings, add-ins and sign-in. If the new install is worse, Roll back brings it back."
                 : "Without it there is no way back to the bottle you have now: its settings, add-ins and sign-in are gone.")
                .font(.callout).foregroundStyle(keepPoint && pointPossible ? Color.secondary : .red).fixedSize(horizontal: false, vertical: true)
        }
        Text("Deleted").font(.headline)
        lines(p.delete)
        if p.addinsReset == true { Text("Reset: Revit's settings and add-ins in the bottle.").font(.callout) }
        ForEach(p.kept ?? [], id: \.self) { Text("Kept: \($0)").font(.callout) }
        // a line that names a command is for the terminal: the sheet says the same in words
        ForEach(p.notes.filter { !$0.contains("./revit") }, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }

    private func lines(_ items: [PlanItem], upTo: Bool = false) -> some View {
        ForEach(items, id: \.label) { i in
            HStack {
                Text(i.label).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let b = i.bytes {
                    let size = ByteCountFormatter().string(fromByteCount: b)
                    Text(upTo ? "up to \(size)" : size).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    private var title: String {
        switch request {
        case .plan(.remove): String(localized: "Remove Revit \(String(year)) (\(bottle))?")
        case .plan(.update): String(localized: "Update Revit \(String(year)) (\(bottle))?")
        case .plan: String(localized: "Rebuild Revit \(String(year)) (\(bottle))?")
        case .rollback: String(localized: "Roll back Revit \(String(year)) (\(bottle))?")
        case .points: String(localized: "Delete restore points of \(bottle)?")
        }
    }

    private var goWord: String {
        switch request {
        case .plan(.remove): String(localized: "Remove")
        case .plan(.update): String(localized: "Update")
        case .plan: String(localized: "Rebuild")
        case .rollback: String(localized: "Roll Back")
        case .points: String(localized: "Delete")
        }
    }

    private var destructive: Bool {
        switch request {
        case .rollback: false
        case .plan(.rebuild), .plan(.update): !(keepPoint && pointPossible)
        default: true
        }
    }

    private func reset() {
        var needsYear = false
        if case .plan = request { needsYear = true }
        gate = SheetGate(year: needsYear ? year : nil)
        keepPoint = pointPossible
    }

    private func read() async -> LoadedPlan? {
        let args: [String]
        switch request {
        case .plan(let r): args = r.planArguments
        case .rollback(_, _, let id): args = ["rollback", String(year), bottle, "--to", id, "--dry-run", "--json"]
        case .points(_, _, let c): args = ["points", String(year), bottle, "--clear", c, "--dry-run", "--json"]
        }
        guard let out = await app.query(args) else { problem = app.engineError ?? ""; return nil }
        let d = JSONDecoder.engine
        var p: LoadedPlan?
        if out.exitCode == 0 {
            switch request {
            case .plan: p = (try? d.decode(RemovePlan.self, from: out.stdout)).map { .bottle($0) }
            case .rollback: p = (try? d.decode(RollbackPlan.self, from: out.stdout)).map { .rollback($0) }
            case .points: p = (try? d.decode(PointsPlan.self, from: out.stdout)).map { .points($0) }
            }
        }
        problem = p == nil ? out.stderr.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return p
    }

    private func go() {
        working = true
        going = Task {
            defer { working = false }
            guard let shown = plan, let now = await read() else { plan = nil; return }
            guard !Task.isCancelled else { return }
            guard now.fingerprint == shown.fingerprint else { plan = now; changed = true; reset(); return }
            let run: RunRequest
            switch (request, now) {
            case (.plan(let r), _): run = r.keeping(point: isRebuild ? keepPoint && pointPossible : true)
            case (.rollback(let y, let b, let id), _): run = .rollback(year: y, bottle: b, id: id)
            case (_, .points(let p)): run = .clearPoints(year: year, bottle: bottle, ids: p.ids, clearUnfinished: p.unfinished)
            default: return
            }
            dismiss()
            await Confirm.start(app: app, env: env, run)
        }
    }
}
