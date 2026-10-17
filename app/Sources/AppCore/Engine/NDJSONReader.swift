// Reads events.ndjson while the engine still writes it: each call returns the events of the lines completed since the
// last one. A torn last line waits for its newline; a line that is not an event is skipped and counted.
import Foundation

public struct NDJSONReader {
    public let url: URL
    public private(set) var malformed = 0
    private var offset: UInt64 = 0
    private var pending = Data()

    public init(url: URL) { self.url = url }

    /// The events of the lines completed since the last call; [] for a file that does not exist yet.
    public mutating func readNew() throws -> [EngineEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: offset)
        let data = try h.readToEnd() ?? Data()
        offset += UInt64(data.count)
        pending.append(data)
        var events: [EngineEvent] = []
        while let nl = pending.firstIndex(of: 0x0a) {
            let line = pending[pending.startIndex..<nl]
            pending.removeSubrange(pending.startIndex...nl)
            if let s = String(data: line, encoding: .utf8), let e = EventParser.parse(s) { events.append(e) } else { malformed += 1 }
        }
        return events
    }
}
