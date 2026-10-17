// Runs one of the Mac's programs for the wizard (osascript, brew) off the main actor: an argument list, the given
// environment, its output into a log (or stderr kept when there is none). A log that cannot be opened stops it before
// anything runs, and output is always drained, so a chatty program never blocks on a full pipe.
import Foundation

public struct RunnerError: Error, LocalizedError {
    public let text: String
    public init(text: String) { self.text = text }
    public var errorDescription: String? { text }
}

public enum ProcessRunner {
    public static func run(_ path: String, _ args: [String], env: [String: String], log: URL?) async throws -> (status: Int32, stderr: String) {
        var logHandle: FileHandle?
        if let log {
            guard FileManager.default.createFile(atPath: log.path, contents: nil), let h = try? FileHandle(forWritingTo: log) else {
                throw RunnerError(text: String(localized: "Cannot write \(log.path)."))
            }
            logHandle = h
        }
        let handle = logHandle
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                defer { try? handle?.close() }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path); p.arguments = args; p.environment = env
                p.standardInput = FileHandle.nullDevice
                let err = Pipe()
                if let handle { p.standardOutput = handle; p.standardError = handle } else { p.standardOutput = FileHandle.nullDevice; p.standardError = err }
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let e = handle == nil ? err.fileHandleForReading.readDataToEndOfFile() : Data()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: e, as: UTF8.self)))
            }
        }
    }
}

/// What a notification carries in its userInfo: the link a click opens (a log folder, a release page).
public enum NotificationLink {
    public static func userInfo(_ url: URL?, release: Bool = false) -> [String: String] {
        var d: [String: String] = [:]
        if let url { d["url"] = url.absoluteString }
        if release { d["kind"] = "release" }
        return d
    }
    public static func url(from info: [AnyHashable: Any]) -> URL? { (info["url"] as? String).flatMap(URL.init(string:)) }
    public static func isRelease(_ info: [AnyHashable: Any]) -> Bool { info["kind"] as? String == "release" }
}
