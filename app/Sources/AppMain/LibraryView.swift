// The Library: a card per Revit, a place to drop a file, restore points of Revits that are gone, what was left running.
import AppCore
import SwiftUI

struct LibraryView: View {
    let app: AppModel
    let env: AppEnvironment
    @State private var left = 0
    @State private var targeted = false
    private static let types = ["rvt", "rfa", "rte", "rft"]

    var body: some View {
        let c = LibraryContent.make(status: app.status, watched: app.watched, starting: Set(app.revitStarting.keys))
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.doc").font(.title2).foregroundStyle(.secondary)
                    Text("Drop a Revit file here or on the Dock icon. It opens in the Revit it was saved with.")
                    Spacer()
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Color.accentColor : .secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter { Self.types.contains($0.pathExtension.lowercased()) }
                    guard !files.isEmpty else { return false }
                    Task { await env.files?.add(files) }
                    return true
                } isTargeted: { targeted = $0 }

                if c.cards.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No Revit on this Mac yet.").font(.headline)
                        Button("Add Revit version…") { env.router.open(.wizard) }.disabled(app.isBusy)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(c.cards, id: \.bottle) { Card(app: app, env: env, card: $0) }
                }
                if !c.orphans.isEmpty { orphans(c.orphans) }
                if left > 0 {
                    Button { env.router.open(.run) } label: {
                        Label(String(localized: "\(left) program(s) still running after Revit quit. Review…"), systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(.plain).foregroundStyle(.orange)
                }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Library")
        .task {   // only while the Library shows
            while !Task.isCancelled {
                if case let .report(r) = await app.cleanup(all: false, dryRun: true) { left = r.items.count }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func orphans(_ list: [OrphanPoints]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Restore points without a Revit").font(.headline)
            ForEach(list, id: \.bottle) { o in
                ForEach(o.points, id: \.id) { p in
                    HStack {
                        Text("Revit \(String(o.year)) · \(o.bottle)")
                        Text(PointTime.text(p.time)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Roll back…") { env.router.ask(.rollback(year: o.year, bottle: o.bottle, id: p.id)) }.disabled(app.isBusy)
                    }
                }
                HStack {
                    Spacer()
                    Button("Delete…", role: .destructive) { env.router.ask(.points(year: o.year, bottle: o.bottle, clear: "all")) }.disabled(app.isBusy)
                }
            }
        }
    }
}

private struct Card: View {
    let app: AppModel
    let env: AppEnvironment
    let card: VersionCard
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { env.router.page(card.ref) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Revit \(String(card.year))").font(.headline)
                    Text(card.tested.isEmpty ? card.bottle : "\(card.bottle) · \(card.tested)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                StatusPill(status: card.status)
                if card.running { Text("Running").font(.caption).foregroundStyle(.tint) }
                if card.hasPoint { Text("Restore point").font(.caption).foregroundStyle(.secondary) }
            }
            Text(card.note).font(.callout).foregroundStyle(.secondary).lineLimit(2).frame(minHeight: 34, alignment: .topLeading)
            HStack {
                RevitButton(app: app, year: card.year, bottle: card.bottle, running: card.running, pids: card.pids, blocked: card.taskHere)
                let viewer = AppLinks.viewerApp(year: card.year, bottle: card.bottle, home: home)
                if !card.running, !card.starting, FileManager.default.fileExists(atPath: viewer.path) {
                    Button("Viewer") { app.noteStarting(bottle: card.bottle); NSWorkspace.shared.open(viewer) }
                }
                Spacer()
                Button { env.router.page(card.ref) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Revit \(String(card.year)) page")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
    }
}
