// SpawnProbe <engine> <ctx> <args…> (a test helper, not shipped): starts a run the way the app does, prints
// "<pid> <process start>" and exits at once — a stand-in for the app quitting while its run goes on.
import AppCore
import Foundation

let a = CommandLine.arguments
guard a.count >= 3 else { FileHandle.standardError.write(Data("usage: SpawnProbe <engine> <ctx> <args…>\n".utf8)); exit(2) }
let engine = ProcessEngine(engine: URL(fileURLWithPath: a[1]), environment: EngineEnvironment.make(from: ProcessInfo.processInfo.environment))
do {
    let pid = try await engine.start(Array(a.dropFirst(3)), ctx: URL(fileURLWithPath: a[2]))
    print("\(pid) \(await engine.processStart(pid: pid) ?? "")")
    exit(0)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1)
}
