// The engine as the helper uses it: revit status --json for the bottles and their Revit processes, with the small
// environment the app gives the engine (AppCore's EngineEnvironment; the helper does not link AppCore), without the
// tests' FAKE_ variables: what the helper starts runs with its permission.
import Foundation

/// From the helper's environment (development), or — bundled: whoever starts the helper sets its environment, and
/// REVIT_CX, REVIT_DATA or HOME would steer what the engine runs with the helper's permission — from the account only.
public func engineEnvironment(from env: [String: String], bundled: Bool = false) -> [String: String] {
    var out: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    if bundled {
        if let pw = getpwuid(getuid()) {
            out["HOME"] = String(cString: pw.pointee.pw_dir)
            out["USER"] = String(cString: pw.pointee.pw_name); out["LOGNAME"] = out["USER"]
        }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 {
            out["TMPDIR"] = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return out
    }
    for k in ["HOME", "USER", "LOGNAME", "TMPDIR", "REVIT_DATA", "REVIT_LOCK_DIR", "REVIT_CX"] { if let v = env[k] { out[k] = v } }
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
            DispatchQueue.global().async {   // through Spawn: the engine gets none of the helper's permission
                var o: [Int32] = [-1, -1]
                guard pipe(&o) == 0 else { cont.resume(returning: []); return }
                let p = Spawn.run(["/bin/bash", engine.path, "status", "--json"], environment: environment, stdin: -1,
                                  stdout: o[1], newGroup: false)
                close(o[1])
                let d = FileHandle(fileDescriptor: o[0], closeOnDealloc: true).readDataToEndOfFile()
                guard let p else { cont.resume(returning: []); return }
                var st: Int32 = 0
                while waitpid(p, &st, 0) == -1 && errno == EINTR {}
                let s = st == 0 ? try? JSONDecoder().decode(Status.self, from: d) : nil
                cont.resume(returning: (s?.bottles ?? []).compactMap { b in
                    Int(b.year).map { EngineBottle(bottle: b.name, year: $0, pids: b.revitPids ?? []) }
                })
            }
        }
    }
}
