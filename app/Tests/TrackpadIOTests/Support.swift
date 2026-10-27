// Helpers for the TrackpadIO tests: fixtures next to this file, temporary folders, waiting for a condition.
import Foundation

func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures").appending(path: name)
}

func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appending(path: "trackpadio-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// Polls the condition every 20 ms for up to `seconds`; true when it came true.
func eventually(_ seconds: Double = 5, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if cond() { return true }; usleep(20_000) }
    return cond()
}

/// Whether a process whose command line contains the text is alive.
func alive(_ text: String) -> Bool {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", text]
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus == 0
}
