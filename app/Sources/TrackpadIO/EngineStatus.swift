// The engine as the helper uses it: revit status --json for the bottles and their Revit processes, with the same small
// environment the app gives the engine (AppCore's EngineEnvironment; the helper does not link AppCore).
import Foundation

public func engineEnvironment(from env: [String: String]) -> [String: String] {
    var out: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    for k in ["HOME", "USER", "LOGNAME", "TMPDIR", "REVIT_DATA", "REVIT_LOCK_DIR", "REVIT_CX"] { if let v = env[k] { out[k] = v } }
    for (k, v) in env where k.hasPrefix("FAKE_") { out[k] = v }
    return out
}

public struct EngineStatusReader: EnginePort {
    let engine: URL, environment: [String: String]
    public init(engine: URL, environment: [String: String]) { self.engine = engine; self.environment = environment }

    private struct Status: Decodable { let bottles: [B] }
    private struct B: Decodable {
        let name: String, year: String
        let revitPids: [Int32]?
        enum CodingKeys: String, CodingKey { case name, year, revitPids = "revit_pids" }
    }

    /// The bottles of a known year; [] when the engine cannot answer.
    public func status() async -> [EngineBottle] {
        let engine = engine, environment = environment
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process(), out = Pipe()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [engine.path, "status", "--json"]
                p.environment = environment
                p.standardInput = FileHandle.nullDevice; p.standardOutput = out; p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { cont.resume(returning: []); return }
                let d = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let s = p.terminationStatus == 0 ? try? JSONDecoder().decode(Status.self, from: d) : nil
                cont.resume(returning: (s?.bottles ?? []).compactMap { b in
                    Int(b.year).map { EngineBottle(bottle: b.name, year: $0, pids: b.revitPids ?? []) }
                })
            }
        }
    }
}
