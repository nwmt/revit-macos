// The helper's log: one line each, a time first; past the limit the file moves to trackpad.log.1.
import Foundation
import Testing
@testable import TrackpadIO

@Test func linesAndRotation() {
    let d = tempDir(), u = d.appending(path: "trackpad.log")
    let log = TrackpadLog(url: u, limit: 200)
    for i in 0..<20 { log.line("line \(i) of the log") }
    log.flush()
    let cur = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
    let old = (try? String(contentsOf: d.appending(path: "trackpad.log.1"), encoding: .utf8)) ?? ""
    #expect(cur.hasSuffix("line 19 of the log\n")); #expect(!old.isEmpty)
    #expect(cur.utf8.count <= 260)
    #expect(cur.split(separator: "\n").allSatisfy { $0.range(of: #"^\d{4}-\d\d-\d\dT"#, options: .regularExpression) != nil })
}
