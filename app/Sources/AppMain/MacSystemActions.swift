// The wizard's Mac side: Rosetta through osascript (macOS asks for the administrator's password), Homebrew for
// CrossOver, NSWorkspace for web pages. Processes get argument arrays, never shell strings of user input.
import AppCore
import AppKit

struct SystemError: Error, LocalizedError { let text: String; var errorDescription: String? { text } }

@MainActor final class MacSystemActions: SystemActions {
    func installRosetta() async throws {
        let script = "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"
        let r = await Self.run("/usr/bin/osascript", ["-e", script], env: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], log: nil)
        if r.status != 0 { throw SystemError(text: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func brew() -> URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    func brewInstall(_ args: [String], log: URL) async throws {
        guard let b = brew() else { throw SystemError(text: String(localized: "Homebrew is not installed.")) }
        var env = ["PATH": b.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        for k in ["HOME", "USER", "LOGNAME", "TMPDIR"] { env[k] = ProcessInfo.processInfo.environment[k] }
        let r = await Self.run(b.path, args, env: env, log: log)
        if r.status != 0 { throw SystemError(text: String(localized: "brew \(args.joined(separator: " ")) failed; see \(log.path)")) }
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    /// Runs a program off the main actor; its output to log (or stderr captured when there is no log).
    nonisolated static func run(_ path: String, _ args: [String], env: [String: String], log: URL?) async -> (status: Int32, stderr: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path); p.arguments = args; p.environment = env
                p.standardInput = FileHandle.nullDevice
                let err = Pipe()
                if let log, FileManager.default.createFile(atPath: log.path, contents: nil), let h = try? FileHandle(forWritingTo: log) {
                    p.standardOutput = h; p.standardError = h
                } else {
                    p.standardOutput = FileHandle.nullDevice; p.standardError = err
                }
                do { try p.run() } catch { cont.resume(returning: (-1, "\(error)")); return }
                let e = log == nil ? err.fileHandleForReading.readDataToEndOfFile() : Data()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: e, as: UTF8.self)))
            }
        }
    }
}
