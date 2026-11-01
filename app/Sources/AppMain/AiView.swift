// The AI Assistant tab of a Revit: its connections, the log of calls, a new connection, and Revit shown to computer use.
import AppCore
import AppKit
import LocalAuthentication
import SwiftUI

/// The system's own question, Touch ID or the Mac's password. Nothing in this app's windows can answer it.
@MainActor struct SystemGrant: GrantGate {
    func ask(_ reason: String) async -> Grant {
        NSApp.activate()   // a question from an app in the background may not show
        let c = LAContext()
        var e: NSError?
        guard c.canEvaluatePolicy(.deviceOwnerAuthentication, error: &e) else {
            return .refused(e?.localizedDescription ?? String(localized: "This Mac cannot ask."))
        }
        do {
            return try await c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .allowed : .refused(String(localized: "Not confirmed."))
        } catch { return .refused(error.localizedDescription) }
    }
}

struct AiTab: View {
    let app: AppModel
    let env: AppEnvironment
    let ref: BottleRef
    let bottle: Bottle
    @State private var model: McpModel?
    @State private var adding = false
    @State private var shown: String?
    @State private var showError: String?

    var body: some View {
        Group {
            if let model { content(model) } else { ProgressView() }
        }
        .task(id: ref) {
            let m = McpModel(app: app, gate: SystemGrant(), year: ref.year, bottle: ref.bottle)
            model = m
            await m.load()
        }
    }

    private func content(_ m: McpModel) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connections").font(.headline)
                if m.tokens.isEmpty { Text("No assistant is connected to this Revit.").foregroundStyle(.secondary) }
                ForEach(m.tokens, id: \.name) { t in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.name)
                            Text("\(t.server) · \(t.tier)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke…") { revoke(m, t) }
                    }
                }
                if let p = m.problem { Text(p).font(.callout).foregroundStyle(.red) }
                Button("New connection…") { adding = true }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Before you connect").font(.headline)
                Text("Your assistant sends what it reads from the model to its provider. Anyone using this Mac under your account can connect. A token is a permission, not a lock.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Let an assistant see Revit").font(.headline)
                Text("Computer use tools then see Revit's windows, with the model in them, and can press what is on screen. Computer use asks you for its own permission. Revoke does not end this; it ends when Revit quits.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Show Revit to computer use…") { Task { await showToAgent(m) } }.disabled(!bottle.running)
                if !bottle.running { Text("Revit is not running.").font(.caption).foregroundStyle(.secondary) }
                if let s = shown { Text(s).font(.callout) }
                if let e = showError { Text(e).font(.callout).foregroundStyle(.red) }
            }
            DisclosureGroup("Call log") {
                if m.calls.isEmpty { Text("No calls yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                ForEach(Array(m.calls.prefix(200).enumerated()), id: \.offset) { _, c in
                    HStack(spacing: 10) {
                        Text(PointTime.text(c.ts ?? "")).font(.caption).foregroundStyle(.secondary)
                        Text(c.tool ?? "?").font(.callout)
                        Spacer()
                        Text(c.client ?? "").font(.caption).foregroundStyle(.secondary)
                        Text(word(c.outcome)).font(.caption).foregroundStyle(c.outcome == "refused" || c.outcome == "error" ? .red : .secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $adding, onDismiss: { Task { await m.load() } }) { NewConnectionSheet(model: m) }
    }

    private func word(_ outcome: String) -> String {
        switch outcome {
        case "refused": String(localized: "Refused")
        case "error": String(localized: "MCP error")
        case "no_answer": String(localized: "No answer")
        default: String(localized: "Answered")
        }
    }

    private func revoke(_ m: McpModel, _ t: McpToken) {
        guard Confirm.ask(String(localized: "Revoke \(t.name)?"),
                          String(localized: "It ends within two seconds. What Revit is already doing goes on. The assistant keeps this connection in its list until you remove it there."),
                          button: String(localized: "Revoke"), destructive: true) else { return }
        Task { await m.revoke(t.name) }
    }

    private func showToAgent(_ m: McpModel) async {
        shown = nil; showError = nil
        switch await m.showToAgent() {
        case .success(let s): shown = s
        case .failure(let e): showError = e.description
        }
    }
}

private struct NewConnectionSheet: View {
    let model: McpModel
    @State private var server = ""
    @State private var tier = "read"
    @State private var client = McpClient.claudeCode
    @State private var working = false
    @State private var problem: String?
    @State private var issued: McpIssued?
    @Environment(\.dismiss) private var dismiss

    private var picked: McpServerInfo? { model.servers.first { $0.id == server } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New connection").font(.title3.bold())
            if let i = issued { result(i) } else { form }
        }
        .padding(20).frame(width: 560, alignment: .topLeading)
        .interactiveDismissDisabled(working || issued != nil)   // a token is being made, or is shown only here
        .onAppear { server = model.servers.first(where: \.ready)?.id ?? model.servers.first?.id ?? "" }
    }

    @ViewBuilder private var form: some View {
        if model.servers.isEmpty { Text("This Revit has no server for an assistant here.").foregroundStyle(.secondary) }
        ForEach(model.servers, id: \.id) { s in
            HStack(alignment: .top) {
                Image(systemName: server == s.id ? "largecircle.fill.circle" : "circle")
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name)
                    if !s.ready { Text(s.missing).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .contentShape(Rectangle()).opacity(s.ready ? 1 : 0.6)
            .onTapGesture { if s.ready { server = s.id; if !s.tiers.contains(tier) { tier = "read" } } }
        }
        if let s = picked, s.ready {
            Text(s.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Access", selection: $tier) { ForEach(s.tiers, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
            Text(McpTier.text(tier, server: s.id)).font(.callout).foregroundStyle(tier == "read" ? Color.secondary : .orange)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Assistant", selection: $client) {
                Text("Claude Code").tag(McpClient.claudeCode); Text("Claude Desktop").tag(McpClient.claudeDesktop)
            }
        }
        if let p = problem { Text(p).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
            Button("Create…") { create() }.keyboardShortcut(.defaultAction).disabled(picked?.ready != true || working)
        }
    }

    private func create() {
        guard let s = picked else { return }
        working = true; problem = nil
        Task {
            defer { working = false }
            switch await model.issue(server: s, tier: tier, client: client) {
            case .issued(let i): issued = i
            case .refused(let why): problem = why
            }
        }
    }

    @ViewBuilder private func result(_ i: McpIssued) -> some View {
        Text("This token is shown once.").font(.headline)
        HStack {
            Text(i.token).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Copy") { Clip.copy(i.token) }
        }
        if i.client == .claudeCode {
            Text("Run this in Terminal. The token then sits in plain text in ~/.claude.json and in your shell history.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Button("Copy the command") { Clip.copy(i.addCommand) }
            Text("If it says the name exists, first run: \(i.removeCommand)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        } else if let b = i.bundle {
            Text("In Claude Desktop: Settings, Extensions, Advanced settings, Install Extension. Choose the file and paste the token.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Button("Show the file") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: b)]) }
        }
        Text("The assistant starts Revit's server when it connects: reconnect it after Revit is open.").font(.caption).foregroundStyle(.secondary)
        HStack { Spacer(); Button("I saved it") { issued = nil; dismiss() }.keyboardShortcut(.defaultAction) }
    }
}

/// A token does not stay on the clipboard: after a minute it goes, unless something else was copied since.
@MainActor private enum Clip {
    static func copy(_ s: String) {
        let p = NSPasteboard.general
        p.clearContents(); p.setString(s, forType: .string)
        let n = p.changeCount
        Task { try? await Task.sleep(for: .seconds(60)); if p.changeCount == n { p.clearContents() } }
    }
}
