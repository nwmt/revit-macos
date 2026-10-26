// revit status --json as the helper reads it: the bottles with their Revit processes.
import Foundation
import Testing
@testable import TrackpadIO

@Test func statusOfTheEngine() async throws {
    let d = tempDir(), e = d.appending(path: "revit")
    try """
    #!/bin/bash
    [ "$1 $2" = "status --json" ] || exit 2
    echo '{"crossover":{"found":true},"bottles":[{"name":"rvt2027-a","year":"2027","revit":true,"running":true,"revit_pids":[500,501],"addins":[]},{"name":"x","year":"","revit":false,"running":false,"addins":[]}]}'
    """.write(to: e, atomically: true, encoding: .utf8)
    let r = await EngineStatusReader(engine: e, environment: ["PATH": "/usr/bin:/bin"]).status()
    #expect(r == [EngineBottle(bottle: "rvt2027-a", year: 2027, pids: [500, 501])])
}

@Test func engineEnvironmentKeepsOnlyWhatTheEngineNeeds() {
    let env = engineEnvironment(from: ["HOME": "/h", "TMPDIR": "/t", "SECRET": "x", "PATH": "/x", "REVIT_CX": "/cx"])
    #expect(env == ["HOME": "/h", "TMPDIR": "/t", "REVIT_CX": "/cx", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"])
}
