// Helpers for the tests: fixtures next to this file (no SwiftPM resources), fresh temporary folders, appending to files.
import Foundation

/// A file under Fixtures/, e.g. fixture("events/install-ok.ndjson").
func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures").appending(path: name)
}

/// A new empty folder under the system's temporary folder.
func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appending(path: "appcore-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// Appends text to a file, creating it.
func append(_ url: URL, _ text: String) {
    append(url, Data(text.utf8))
}

/// The environment of every process a test starts: nothing of the test process's own except USER and LOGNAME.
enum TestEnv {
    static let basePath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// HOME, TMPDIR, REVIT_LOCK_DIR, REVIT_DATA and REVIT_CX under root (made here), a plain PATH (+ extraPath),
    /// LANG=en_US.UTF-8, plus fake.
    static func make(root: URL, extraPath: String? = nil, fake: [String: String] = [:]) -> [String: String] {
        var env: [String: String] = [:]
        for (k, sub) in [("HOME", "home"), ("TMPDIR", "tmp"), ("REVIT_LOCK_DIR", "lock"), ("REVIT_DATA", "data"), ("REVIT_CX", "cx")] {
            let d = root.appending(path: sub)
            try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            env[k] = d.path
        }
        let me = ProcessInfo.processInfo.environment
        env["USER"] = me["USER"] ?? "x"; env["LOGNAME"] = me["LOGNAME"] ?? env["USER"]
        env["PATH"] = basePath + (extraPath.map { ":" + $0 } ?? "")
        env["LANG"] = "en_US.UTF-8"
        env.merge(fake) { _, new in new }
        return env
    }
}

/// The fake engine (Fixtures/fake-revit.sh).
var fakeEngine: URL { fixture("fake-revit.sh") }

/// Polls cond every 50 ms until it holds or the time is up; true when it held.
func waitFor(_ seconds: Double = 5, isolation: isolated (any Actor)? = #isolation, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return cond()
}

/// The text of a file, or "" when it is not there.
func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

/// Ends a process group a test started, whatever the test's outcome.
func killGroup(_ pgid: Int32) { if pgid > 1 { kill(-pgid, SIGKILL) } }

func append(_ url: URL, _ data: Data) {
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    let h = try! FileHandle(forWritingTo: url)
    h.seekToEndOfFile(); h.write(data); try! h.close()
}
