// The hittest client (spec §4, plan task 6): the fake engine plays "revit hittest"; short timings keep the tests fast.
// The tests start processes: app/test.sh runs them one at a time.
import CoreGraphics
import Foundation
import Testing
@testable import TrackpadCore
@testable import TrackpadIO

struct Fake {
    let dir = tempDir()
    var count: URL { dir.appending(path: "count") }
    var starts: Int { ((try? String(contentsOf: count, encoding: .utf8)) ?? "").split(separator: "\n").count }
    func client(_ mode: String, scale: Int? = 2) -> HittestClient {
        let env = ["PATH": "/usr/bin:/bin", "FAKE_HIT_MODE": mode, "FAKE_HIT_COUNT": count.path]
        return HittestClient(engine: fixture("fake-revit-hittest.sh"), year: 2027, bottle: "rvt2027-t", environment: env,
                             log: TrackpadLog(url: dir.appending(path: "trackpad.log")),
                             scale: { _ in scale }, timing: ClientTiming(hello: 1, reply: 0.15, restart: 0.2, termGrace: 0.3))
    }
}

func ready(_ c: HittestClient) -> Bool { eventually { if case .ready = c.status { return true }; return false } }

@Test func readyAndAnswers() {
    let f = Fake(), c = f.client("normal"); c.start(); defer { c.stop() }
    #expect(ready(c)); #expect(c.status == .ready(scale: 2))
    let r = c.query(WinePoint(x: 1512, y: 900))
    #expect(r?.chain == [HitWindow(cls: "AfxFrameOrView140u", title: ""), HitWindow(cls: "A", title: "Floor Plan: 1512 900")])
    #expect(c.query(WinePoint(x: 1, y: 2))?.chain.last?.title == "Floor Plan: 1 2")
}

@Test func unknownDisplayLayoutIsNotReady() {
    let f = Fake(), c = f.client("normal", scale: nil); c.start(); defer { c.stop() }
    #expect(eventually { c.status == .notReady("unknown display layout") })
    #expect(c.query(WinePoint(x: 1, y: 2)) == nil)
}

@Test func noHelloRestarts() {
    let f = Fake(), c = f.client("nohello"); c.start(); defer { c.stop() }
    #expect(eventually(5) { f.starts >= 2 })
}

@Test func slowAnswersTimeOutThenRestart() {
    let f = Fake(), c = f.client("slow"); c.start(); defer { c.stop() }
    #expect(ready(c))
    let t = Date(); #expect(c.query(WinePoint(x: 1, y: 1)) == nil); #expect(Date().timeIntervalSince(t) < 0.25)
    usleep(400_000)                                    // the late answer arrives: it is not taken by the next query
    #expect(c.query(WinePoint(x: 1, y: 1)) == nil)     // second miss in a row: transport failure
    #expect(eventually(5) { f.starts >= 2 })
}

@Test func wrongSeqIsDropped() {
    let f = Fake(), c = f.client("wrongseq"); c.start(); defer { c.stop() }
    #expect(ready(c)); #expect(c.query(WinePoint(x: 1, y: 1)) == nil)
}

@Test func overlongLineRestarts() {
    let f = Fake(), c = f.client("long"); c.start(); defer { c.stop() }
    #expect(ready(c)); _ = c.query(WinePoint(x: 1, y: 1))
    #expect(eventually(5) { f.starts >= 2 })
}

@Test func busyRetriesWithoutFailing() {
    let f = Fake(), c = f.client("busy"); c.start(); defer { c.stop() }
    #expect(eventually(5) { f.starts >= 4 }); #expect(eventually { c.status == .retryLater })
}

@Test func threeCrashesFail() {
    let f = Fake(), c = f.client("crash"); c.start(); defer { c.stop() }
    #expect(eventually(5) { if case .failed = c.status { return true }; return false })
    let n = f.starts; usleep(600_000); #expect(f.starts == n); #expect(n == 3)
}

@Test func stopEndsTheGroupAndStartsNothing() {
    let f = Fake(), c = f.client("normal"); c.start()
    #expect(ready(c)); #expect(alive("sleep 61."))
    c.stop()
    #expect(c.status == .stopped)
    #expect(eventually(3) { !alive("sleep 61.") })
    let n = f.starts; usleep(600_000); #expect(f.starts == n)
}

@Test func queryDuringStopReturnsSoon() {
    let f = Fake(), c = f.client("slow"); c.start()
    #expect(ready(c))
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { c.stop() }
    let t = Date(); #expect(c.query(WinePoint(x: 1, y: 1)) == nil); #expect(Date().timeIntervalSince(t) < 0.2)
}

@Test func lateAnswerOfAnOldProcessIsNotTaken() {
    let f = Fake(), c = f.client("slow"); c.start(); defer { c.stop() }
    #expect(ready(c))
    #expect(c.query(WinePoint(x: 1, y: 1)) == nil)
    c.restart()                                        // a new process, a new generation
    #expect(ready(c))
    #expect(c.query(WinePoint(x: 2, y: 2)) == nil)     // the slow fake answers late again; the old answer is not this one
}
