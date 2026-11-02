// Add Revit version, a sheet over the main window (the first run too): a rail of five steps — This Mac, Tools, Revit
// installer, Check, Install — and the step on the right. After Install the same sheet follows that install until it
// goes; closing it (Hide) leaves the install running in Activity. Every state is WizardModel's; a new showing starts clean.
import AppCore
import SwiftUI
import UniformTypeIdentifiers

struct AddVersionSheet: View {
    @Bindable var wizard: WizardModel
    let app: AppModel
    let env: AppEnvironment
    @State private var pickFile = false
    @State private var pickFolder = false
    @State private var installError: String?

    var body: some View {
        Group {
            if wizard.installCtx != nil { InstallProgressView(wizard: wizard, app: app, env: env) } else { setup }
        }
        .frame(width: 860, height: 500)   // the main window is at least 560 high: the sheet fits with its buttons
        .task { if wizard.macChecks == nil && wizard.macError == nil { await wizard.loadMac() } }
        .onDisappear { wizard.reset() }   // Hide, Done, Cancel, Esc: the next showing starts clean; a run goes on
        .fileImporter(isPresented: $pickFile, allowedContentTypes: [.item]) { r in
            if case .success(let u) = r { Task { await wizard.importMsls31(u) } }
        }
        .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { r in
            if case .success(let u) = r { Task { await wizard.chooseInstaller(u) } }
        }
    }

    // MARK: setup

    private var setup: some View {
        HStack(spacing: 0) {
            rail.frame(width: 220).background(.quaternary.opacity(0.4))
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) { step(wizard.shown) }
                        .padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Divider()
                footer.padding(.horizontal, 28).padding(.vertical, 14)
            }
        }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SETUP").font(.caption.bold()).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 6)
            ForEach(WizardStep.allCases, id: \.self) { s in
                let passed = wizard.passed(s), current = s == wizard.current, shown = s == wizard.shown
                Button { wizard.viewing = current ? nil : s } label: {
                    HStack(spacing: 10) {
                        Image(systemName: passed ? "checkmark.circle.fill" : current ? "circle.inset.filled" : "circle")
                            .foregroundStyle(passed ? .green : current ? Color.accentColor : .secondary)
                        Text(Self.title(s)).fontWeight(shown ? .semibold : .regular).foregroundStyle(passed || current ? .primary : .secondary)
                        Spacer()
                    }
                    .padding(8).contentShape(Rectangle())
                    .background(shown ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain).disabled(!passed && !current)
            }
            Spacer()
            Text("You need your own Revit license and its installer from your Autodesk Account. Nothing is sent anywhere.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(10)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Image(systemName: "powerplug").foregroundStyle(.secondary)
            Text("Takes 10–30 minutes plus the download. Keep the Mac plugged in. You can close this while it runs.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Cancel", role: .cancel) { env.router.close() }.keyboardShortcut(.cancelAction)
            if wizard.viewing != nil {
                Button("Back to \(Self.title(wizard.current))") { wizard.viewing = nil }
            } else if wizard.shown == .install {
                Button("Install Revit") { install() }.keyboardShortcut(.defaultAction).disabled(wizard.state(.install) != .open)
            }
        }
    }

    @ViewBuilder private func step(_ s: WizardStep) -> some View {
        switch s {
        case .mac:
            heading(String(localized: "This Mac"), String(localized: "Checked on its own. Nothing changes."))
            macList(wizard.macChecks ?? [])
        case .tools:
            heading(String(localized: "Tools"), String(localized: "One click each."))
            if let m = wizard.macChecks { macProblems(m) }
            ForEach([WizardRow.rosetta, .crossover, .msls31], id: \.self) { rowView($0) }
        case .installer:
            heading(String(localized: "Revit installer"), String(localized: "The folder with your Revit installer from your Autodesk Account. It is only read."))
            rowView(.installer)
        case .check:
            heading(String(localized: "Check"), String(localized: "What the install needs, checked first. Nothing changes."))
            rowView(.check)
            if wizard.installer != nil {   // the check is of this name: a new name needs a new check
                DisclosureGroup("Advanced: bottle name") {
                    HStack {
                        TextField("rvt2025-a", text: $wizard.bottleName).frame(width: 180)
                        Text("Each Revit lives in a bottle of its own.").font(.callout).foregroundStyle(.secondary)
                    }.padding(.top, 4)
                }
            }
        case .install:
            heading(String(localized: "Install"), String(localized: "Everything is ready."))
            if let i = wizard.installer {
                Text(i.info.complete ? "Revit \(String(i.year)) goes into bottle \(wizard.bottleName)."
                     : "Revit \(String(i.year)) goes into bottle \(wizard.bottleName). The rest of the installer downloads during the install.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .waiting = wizard.state(.install), let b = wizard.busyText { Text("Busy: \(b)").foregroundStyle(.secondary) }
            if let e = installError { Text(e).foregroundStyle(.red).textSelection(.enabled) }
        }
    }

    private func heading(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t).font(.title2.bold())
            Text(sub).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func macList(_ checks: [DoctorReport.Check]) -> some View {
        if let e = wizard.macError { Text(e.isEmpty ? String(localized: "Could not check this Mac.") : e).foregroundStyle(.red) }
        else if wizard.macChecks == nil { ProgressView().controlSize(.small) }
        else { HealthList(checks: checks) }
    }

    /// On the Tools step: only what This Mac found wrong.
    @ViewBuilder private func macProblems(_ checks: [DoctorReport.Check]) -> some View {
        let bad = checks.filter { $0.status == "warn" || $0.status == "fail" }
        if !bad.isEmpty { GroupBox("This Mac") { HealthList(checks: bad).frame(maxWidth: .infinity, alignment: .leading) } }
    }

    // MARK: rows (the checklist's controls)

    @ViewBuilder private func rowView(_ row: WizardRow) -> some View {
        let s = wizard.state(row)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: symbol(s)).foregroundStyle(color(s))
                Text(Self.rowTitle(row)).fontWeight(.semibold)
                Spacer()
                Text(summary(s)).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.trailing)
            }
            if open(s) || row == .installer || row == .check { controls(row, s) }
            if s == .waiting, row == .check, let b = wizard.busyText { Text("Busy: \(b)").foregroundStyle(.secondary) }
        }
        .padding(14).background(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private func open(_ s: RowState) -> Bool {
        switch s { case .open, .failed, .warning, .working: true; default: false }
    }

    @ViewBuilder private func controls(_ row: WizardRow, _ s: RowState) -> some View {
        switch row {
        case .rosetta:
            Text("Revit's installers need Rosetta. Installing it accepts Apple's license for Rosetta; macOS asks for your password.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Install Rosetta…") { Task { await wizard.installRosetta() } }.disabled(s == .working)
        case .crossover:
            Text("CrossOver runs Windows apps on a Mac, without a virtual machine. It is paid, with a free trial.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Install CrossOver…") { Task { await wizard.installCrossOver() } }.disabled(s == .working)
            if let n = wizard.crossoverNote { Text(n).font(.callout) }
        case .msls31:
            Text("Copy C:\\Windows\\System32\\msls31.dll from a licensed Windows 7/10 x64 PC, then drop it here.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            dropZone(String(localized: "Drop msls31.dll here")) { u in Task { await wizard.importMsls31(u) } }
            Button("Choose file…") { pickFile = true }
        case .installer:
            if wizard.installer == nil {
                dropZone(String(localized: "Drop the installer folder here")) { u in Task { await wizard.chooseInstaller(u) } }
                    .disabled(s == .working)
                Button("Choose folder…") { pickFolder = true }.disabled(s == .working)
            } else {
                Button("Choose another folder…") { pickFolder = true }.disabled(s == .working)   // another installer, another year
            }
        case .check:
            if wizard.installer != nil {
                Button("Check") { Task { await wizard.runCheck() } }.disabled(s == .working || s == .waiting)
                ForEach(wizard.checkWarnings, id: \.self) { w in Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if wizard.offersSourceChoice {
                    HStack {
                        Button("Use the existing one") { Task { await wizard.choose(.reuseExtracted) } }
                        Button("Unpack again") { Task { await wizard.choose(.reextract) } }
                    }
                }
            }
        case .install:
            EmptyView()
        }
    }

    private func install() {
        installError = nil
        Task {
            do { try await wizard.install() } catch { installError = app.engineError ?? app.busyText.map { String(localized: "Busy: \($0)") } ?? "\(error)" }
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

    static func title(_ s: WizardStep) -> String {
        switch s {
        case .mac: String(localized: "This Mac")
        case .tools: String(localized: "Tools")
        case .installer: String(localized: "Revit installer")
        case .check: String(localized: "Check")
        case .install: String(localized: "Install")
        }
    }

    static func rowTitle(_ r: WizardRow) -> String {
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

/// The install the sheet started: its phases, then the end. Only that run: once another one is watched, Activity has it.
struct InstallProgressView: View {
    let wizard: WizardModel
    let app: AppModel
    let env: AppEnvironment
    @State private var refusal: String?
    @State private var cancelling = false

    var body: some View {
        if let w = app.watched, w.ctx == wizard.installCtx {
            run(w)
        } else {
            VStack(spacing: 14) {
                Text("The install is in Activity.").font(.headline)
                HStack {
                    Button("Show Activity") { env.router.close { env.router.open(.run) } }
                    Button("Done") { env.router.close() }.keyboardShortcut(.defaultAction)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func run(_ w: WatchedRun) -> some View {
        let year = (w.state.year ?? w.record?.request.year).map(String.init) ?? ""
        let bottle = w.state.bottle ?? w.record?.request.bottle ?? ""
        let ended = !(w.phase == .running || w.phase == .finishing)
        let ok = w.succeeded && w.state.end?.kind == .ok
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ok ? "Revit \(year) is ready" : ended ? "Revit \(year)" : "Installing Revit \(year)").font(.title2.bold())
                    Text("Bottle \(bottle)").foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(InstallPhases.make(w.state), id: \.id) { p in phaseRow(p); Divider() }
                    }
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
                    ForEach(Array(w.state.messages.enumerated()), id: \.offset) { _, m in
                        Label(m.text, systemImage: m.level == "error" ? "xmark.octagon" : "exclamationmark.triangle")
                            .foregroundStyle(m.level == "error" ? .red : .orange).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if ended && !ok { ResultView(app: app, env: env, run: w, nav: .sheet(app, env)).padding(.top, 8) }
                }
                buttons(w, ended: ended, ok: ok, year: Int(year), bottle: bottle)
            }
            .padding(28)
            if !ended {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    note("bell", String(localized: "You can close this"),
                         String(localized: "The install goes on. Activity and the menu bar show it, and a notification says when it ends."))
                    note("arrow.clockwise", String(localized: "Connection dropped? Fine."),
                         String(localized: "Retry goes on with the download from where it stopped. Keep the Mac plugged in."))
                    Spacer()
                }
                .padding(20).frame(width: 280).background(.quaternary.opacity(0.4))
            }
        }
    }

    private func phaseRow(_ p: Phase) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(p.state)).foregroundStyle(color(p.state)).frame(width: 18)
            Text(p.title).fontWeight(p.state == .running ? .semibold : .regular)
                .foregroundStyle(p.state == .todo ? .secondary : .primary).frame(width: 200, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(p.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if let pc = p.percent { ProgressView(value: Double(pc), total: 100) }
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(p.state == .running ? Color.accentColor.opacity(0.06) : .clear)
    }

    @ViewBuilder private func buttons(_ w: WatchedRun, ended: Bool, ok: Bool, year: Int?, bottle: String) -> some View {
        HStack {
            Button("Show details") { env.router.close { env.router.open(.run) } }
            Spacer()
            if !ended {
                if let r = refusal { Text(r).foregroundStyle(.secondary) }
                if w.phase == .finishing { Text("Finishing…").foregroundStyle(.secondary) }
                Button("Cancel") { cancel() }.disabled(cancelling || w.phase == .finishing)
                Button("Hide") { env.router.close() }.keyboardShortcut(.defaultAction)
            } else if ok, let y = year {
                Button("Choose add-ins…") { env.router.close { env.router.open(.addins(BottleRef(year: y, bottle: bottle))) } }
                Button("Done") { env.router.close() }
                Button("Open Revit \(String(y))") {
                    // a fresh install is always due for the hint: it comes at once, before any sheet that waited
                    let req = OpenRequest(year: y, bottle: bottle)
                    env.router.close {
                        if SignInHint(defaults: .standard).isOff { Task { await RevitActions.start(app: app, year: y, bottle: bottle, viewer: false) } }
                        else { env.router.show(.signIn(req)) }
                    }
                }.keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { env.router.close() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func cancel() {
        cancelling = true
        Task {
            if case .refused(let why) = await app.cancel() { refusal = why } else { refusal = nil }
            cancelling = false
        }
    }

    private func note(_ icon: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }

    private func symbol(_ s: Phase.State) -> String {
        switch s {
        case .done: "checkmark.circle.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .failed: "xmark.circle.fill"
        case .skipped: "minus.circle"
        case .todo: "circle"
        }
    }

    private func color(_ s: Phase.State) -> Color {
        switch s {
        case .done: .green
        case .running: .accentColor
        case .failed: .red
        default: .secondary
        }
    }
}

/// Before the first Open of a bottle after its install: how this Revit signs in.
struct SignInSheet: View {
    let app: AppModel
    let env: AppEnvironment
    let request: OpenRequest
    @State private var never = false

    var body: some View {
        let bottles = app.status?.bottles ?? []
        let b = bottles.first { $0.name == request.bottle }
        let t = SignInText.make(bottle: request.bottle, signin: b?.support?.signin ?? "",
                                idmgrBottles: bottles.filter { $0.support?.signin == "idmgr" }.map(\.name))
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("One thing to know about signing in").font(.title2.bold())
                Text(t.browser ? "Revit signs in through your Mac's browser. At the end, the browser asks which app should open the link."
                     : "Revit \(String(request.year)) signs in in its own window.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(t.steps.enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(i + 1)").font(.callout.bold()).frame(width: 24, height: 24).background(Circle().fill(.quaternary))
                        Text(s).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let n = t.note {
                Label(n, systemImage: "info.circle").font(.callout).fixedSize(horizontal: false, vertical: true)
                    .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Toggle("Don't show this again", isOn: $never)
                Spacer()
                Button("Cancel", role: .cancel) { env.router.close() }.keyboardShortcut(.cancelAction)
                Button(request.viewer ? "Open Revit Viewer" : "Open Revit \(String(request.year))") { open() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 600, alignment: .topLeading)
    }

    private func open() {
        let hint = SignInHint(defaults: .standard)
        if never { hint.turnOff() }
        let r = request, app = app
        env.router.close {
            Task {
                await app.refresh()   // the run record of a fresh install may have come only now
                hint.mark(bottle: r.bottle, builtTime: app.status?.bottles.first { $0.name == r.bottle }?.built?.time)
                await RevitActions.start(app: app, year: r.year, bottle: r.bottle, viewer: r.viewer)
            }
        }
    }
}
