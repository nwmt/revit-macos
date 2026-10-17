// The wizard's Mac side: Rosetta through osascript (macOS asks for the administrator's password), Homebrew for
// CrossOver and Ghostscript, NSWorkspace for web pages. Processes get argument arrays, never shell strings of user input.
import AppCore
import AppKit

@MainActor final class MacSystemActions: SystemActions {
    func installRosetta() async throws {
        let script = "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"
        let r = try await ProcessRunner.run("/usr/bin/osascript", ["-e", script], env: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], log: nil)
        if r.status != 0 { throw RunnerError(text: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func brew() -> URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    func brewInstall(_ args: [String], log: URL) async throws {
        guard let b = brew() else { throw RunnerError(text: String(localized: "Homebrew is not installed.")) }
        var env = ["PATH": b.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        for k in ["HOME", "USER", "LOGNAME", "TMPDIR"] { env[k] = ProcessInfo.processInfo.environment[k] }
        let r = try await ProcessRunner.run(b.path, args, env: env, log: log)
        if r.status != 0 { throw RunnerError(text: String(localized: "brew \(args.joined(separator: " ")) failed; see \(log.path)")) }
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
