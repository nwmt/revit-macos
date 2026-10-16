// A stub until the real app: a menu bar item and one window that shows whether the bundled engine, its tools and its
// shims work (engine/scripts/check-bundle.sh) and whether the app should be moved to the Applications folder
// (engine/revit status --json). The name comes from Info.plist (app/app.conf), never from this file.
import AppKit
import Observation
import SwiftUI

@main
struct AppMain: App {
    @State private var check = BundleCheck()
    private let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ""

    var body: some Scene {
        Window("Bundle check", id: "check") {
            CheckView(check: check, name: name)
        }
        MenuBarExtra(name, systemImage: "building.columns") {
            CheckButton(check: check)
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}

struct CheckButton: View {
    @Environment(\.openWindow) private var openWindow
    let check: BundleCheck

    var body: some View {
        Button("Check bundle…") {
            check.run()
            openWindow(id: "check")
            NSApp.activate()
        }
    }
}

struct CheckView: View {
    let check: BundleCheck
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if check.placement == "move" {
                Text("Move \(name) to the Applications folder, then open it again.")
                    .font(.headline)
            }
            ScrollView {
                Text(check.running ? "Checking…" : check.output)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 240)
        .onAppear { if check.output.isEmpty && !check.running { check.run() } }
    }
}

@MainActor @Observable
final class BundleCheck {
    var output = ""
    var placement = ""
    var running = false

    func run() {
        guard !running else { return }
        running = true
        Task.detached {
            let out = BundleCheck.engine(["scripts/check-bundle.sh"])
            let status = BundleCheck.engine(["revit", "status", "--json"])
            let placement = BundleCheck.placement(fromStatus: status)
            await MainActor.run {
                self.output = out
                self.placement = placement
                self.running = false
            }
        }
    }

    // /bin/bash <Resources>/engine/<script> <arguments…>: an argument list, no shell string; stdin from /dev/null
    nonisolated static func engine(_ args: [String]) -> String {
        guard let res = Bundle.main.resourceURL, let script = args.first else { return "no Resources folder" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [res.appendingPathComponent("engine").appendingPathComponent(script).path] + args.dropFirst()
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "cannot run \(script): \(error.localizedDescription)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func placement(fromStatus json: String) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let app = obj["app"] as? [String: Any], let p = app["placement"] as? String else { return "" }
        return p
    }
}
