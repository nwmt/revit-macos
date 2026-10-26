// What the helper starts is its own "responsible process": it gets none of the helper's Accessibility permission, so
// even a replaced engine script cannot use it (security review of the helper).
import Darwin
import Foundation
import Testing
@testable import TrackpadIO

@Test func childrenAreTheirOwnResponsibleProcess() throws {
    typealias Resp = @convention(c) (pid_t) -> pid_t
    let sym = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid"))
    let resp = unsafeBitCast(sym, to: Resp.self)
    let p = try #require(Spawn.run(["/bin/sleep", "3"], environment: [:], stdin: -1, stdout: -1, newGroup: true))
    defer { kill(p, SIGTERM); var s: Int32 = 0; waitpid(p, &s, 0) }
    #expect(resp(p) == p)
    #expect(resp(getpid()) != p)
}

@Test func spawnConnectsStdinAndStdout() throws {
    var i: [Int32] = [-1, -1], o: [Int32] = [-1, -1]
    #expect(pipe(&i) == 0); #expect(pipe(&o) == 0)
    let p = try #require(Spawn.run(["/bin/cat"], environment: [:], stdin: i[0], stdout: o[1], newGroup: false))
    close(i[0]); close(o[1])
    _ = "ping\n".withCString { write(i[1], $0, 5) }; close(i[1])
    var buf = [UInt8](repeating: 0, count: 16)
    let n = read(o[0], &buf, 16); close(o[0])
    var s: Int32 = 0; waitpid(p, &s, 0)
    #expect(String(decoding: buf[0..<max(n, 0)], as: UTF8.self) == "ping\n")
}

@Test func outputOfAProgram() throws {
    let r = try #require(Spawn.output(["/bin/echo", "a b"], environment: [:]))
    #expect(r.status == 0); #expect(String(decoding: r.data, as: UTF8.self) == "a b\n")
    #expect(Spawn.output(["/bin/sh", "-c", "exit 3"], environment: [:])?.status == 3)
}
