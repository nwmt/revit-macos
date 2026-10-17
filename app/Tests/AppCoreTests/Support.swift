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

func append(_ url: URL, _ data: Data) {
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    let h = try! FileHandle(forWritingTo: url)
    h.seekToEndOfFile(); h.write(data); try! h.close()
}
