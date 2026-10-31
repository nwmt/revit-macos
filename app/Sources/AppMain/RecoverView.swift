// Revit in trouble: the ladder from the safest step to the last resort, and the recent files a page shows.
import AppCore
import SwiftUI

extension BottleRef: Identifiable { public var id: String { "\(year)\(bottle)" } }

struct RecoverSheet: View {
    let app: AppModel
    let env: AppEnvironment
    let ref: BottleRef
    @Environment(\.dismiss) private var dismiss

    private var bottle: Bottle? { app.status?.bottles.first { $0.name == ref.bottle } }
    private var newest: String? {
        (app.status?.restorePoints ?? []).filter { $0.bottle == ref.bottle && $0.year == String(ref.year) }.map(\.id).sorted().last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Revit \(String(ref.year)) is not responding?").font(.title3.bold())
            Text("Start at the top. Each step goes further than the one before it.").foregroundStyle(.secondary)
            ForEach(Array(RecoverContent.steps(year: ref.year, running: bottle?.running ?? false, busy: app.isBusy, newest: newest).enumerated()), id: \.offset) { i, s in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(i + 1)").font(.callout.bold()).frame(width: 22, height: 22).background(Circle().fill(.quaternary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.body.bold())
                        Text(s.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let o = s.off { Text(o).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Button(s.button) { run(s.action) }.disabled(s.off != nil).tint(s.danger ? .red : .accentColor)
                        Text(s.risk).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack { Spacer(); Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 620, alignment: .topLeading)
    }

    private func run(_ a: RecoverAction) {
        switch a {
        case .show: RevitActions.show(bottle?.revitPids ?? [])
        case .forceQuit:
            guard Confirm.ask(String(localized: "Force quit Revit \(String(ref.year))?"),
                              String(localized: "Unsaved work in Revit \(String(ref.year)) will be lost."),
                              button: String(localized: "Force quit"), destructive: true) else { return }
            Task { await Confirm.start(app: app, env: env, .stop(year: ref.year, bottle: ref.bottle)) }
        case .closeAll: Task { await Confirm.closeAll(app: app) }
        case .check:
            env.router.healthWanted = true
            env.router.page(ref, tab: .maintenance)
            dismiss()
        case .rollBack(let id): env.router.leaveRecover(then: .rollback(year: ref.year, bottle: ref.bottle, id: id))
        case .report: Task { await Report.copy(app: app, year: ref.year, bottle: ref.bottle, logDir: nil) }
        case .rebuild: env.router.leaveRecover(then: .plan(.rebuild(year: ref.year, bottle: ref.bottle, source: nil)))
        }
    }
}

struct RecentList: View {
    let env: AppEnvironment
    let files: [RecentFile]
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(files.prefix(limit).enumerated()), id: \.offset) { _, f in
                Button {
                    if let p = f.path { Task { await env.files?.add([URL(fileURLWithPath: p)]) } }
                } label: {
                    HStack(spacing: 10) {
                        Text(f.kind.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary).frame(width: 30)
                        Text(f.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(f.where).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(f.path == nil)
            }
        }
    }
}
