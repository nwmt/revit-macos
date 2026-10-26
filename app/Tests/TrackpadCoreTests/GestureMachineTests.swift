// The gesture state machine (spec 2026-10-26-trackpad §6): scroll phases 1 began, 2 changed, 4 ended, 8 cancelled,
// 128 may begin; momentum 1 begin, 2 continue, 3 end.
import CoreGraphics
import Testing
@testable import TrackpadCore

let began = 1, changed = 2, ended = 4, cancelled = 8, mayBegin = 128

func sc(_ phase: Int, _ dx: Double = 0, _ dy: Double = 0, at: CGPoint = CGPoint(x: 10, y: 10), mods: Mods = [],
        t: Double = 0, momentum: Int = 0, continuous: Bool = true, ours: Bool = false) -> Input {
    .scroll(ScrollIn(continuous: continuous, phase: phase, momentum: momentum, dx: dx, dy: dy, at: at, mods: mods, time: t, ours: ours))
}
func mg(_ phase: GesturePhase, _ amount: Double = 0, at: CGPoint = CGPoint(x: 10, y: 10), t: Double = 0) -> Input {
    .magnify(MagnifyIn(phase: phase, amount: amount, at: at, time: t, ours: false))
}
let wheel = sc(0, 0, -3, continuous: false)
func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

final class Decide {
    var calls = 0
    var answer: Target? = Target(pid: 500)
    func make() -> GestureMachine { GestureMachine(decide: { _ in self.calls += 1; return self.answer }) }
}

/// Feeds the inputs, returns every post and every pass flag.
func run(_ m: GestureMachine, _ inputs: [Input]) -> (posts: [Post], pass: [Bool]) {
    var posts: [Post] = [], pass: [Bool] = []
    for i in inputs { let r = m.handle(i); posts += r.posts; pass.append(r.pass) }
    return (posts, pass)
}

@Test func panBasic() {
    let m = Decide().make()
    let r = run(m, [sc(began), sc(changed, 5, -3), sc(changed, 5, -3), sc(ended)])
    #expect(r.posts == [.down(pt(10, 10), []), .drag(pt(15, 7), []), .drag(pt(20, 4), []), .up(pt(20, 4), [])])
    #expect(r.pass == [false, false, false, false])
    #expect(m.state == .idle)
}

@Test func momentumAfterPanDropped() {
    let m = Decide().make()
    let r = run(m, [sc(began), sc(changed, 5, 0), sc(ended), sc(0, 3, 0, momentum: 1), sc(0, 2, 0, momentum: 2), sc(0, 0, 0, momentum: 3)])
    #expect(r.pass == [false, false, false, false, false, false])
    #expect(r.posts.count == 3)
    #expect(run(m, [sc(0, 1, 0, momentum: 2)]).pass == [true])   // after momentum end: someone else's momentum passes
}

@Test func momentumAfterPassingPasses() {
    let d = Decide(); d.answer = nil; let m = d.make()
    let r = run(m, [sc(began), sc(changed, 5, 0), sc(ended), sc(0, 3, 0, momentum: 1), sc(0, 0, 0, momentum: 3)])
    #expect(r.pass == [true, true, true, true, true]); #expect(r.posts.isEmpty)
}

@Test func mayBeginThenBeganDecidesOnce() {
    let d = Decide(); let m = d.make()
    let r = run(m, [sc(mayBegin), sc(began), sc(changed, 1, 1), sc(ended)])
    #expect(d.calls == 1)
    #expect(r.posts.filter { if case .down = $0 { return true }; return false }.count == 1)
    #expect(r.pass == [false, false, false, false])
}

@Test func mayBeginThenLiftedWithoutMoving() {
    let d = Decide(); let m = d.make()
    let r = run(m, [sc(mayBegin), sc(cancelled), sc(began)])
    #expect(r.posts == [.down(pt(10, 10), [])]); #expect(d.calls == 2); #expect(r.pass == [false, false, false])
}

@Test func changedWithoutBegan() {
    let d = Decide(); let m = d.make()
    let r = run(m, [sc(changed, 4, 2), sc(ended)])
    #expect(r.posts == [.down(pt(10, 10), []), .drag(pt(14, 12), []), .up(pt(14, 12), [])]); #expect(d.calls == 1)
}

@Test func panLeavesWindowKeepsDragging() {
    let d = Decide(); let m = d.make()
    d.answer = Target(pid: 500); _ = run(m, [sc(began)])
    d.answer = nil   // the point is no longer over a view: the decision stands until the gesture ends
    let r = run(m, [sc(changed, 3000, 0, at: pt(3000, 10)), sc(ended)])
    #expect(r.posts == [.drag(pt(3010, 10), []), .up(pt(3010, 10), [])]); #expect(d.calls == 1)
}

@Test func wheelDuringPanDrops() {
    let m = Decide().make()
    let r = run(m, [sc(began), sc(changed, 1, 0), wheel, sc(changed, 1, 0), sc(ended), sc(0, 1, 0, momentum: 2)])
    #expect(r.posts == [.down(pt(10, 10), []), .drag(pt(11, 10), []), .up(pt(11, 10), [])])
    #expect(r.pass == [false, false, true, false, false, false])
    #expect(run(m, [sc(began)]).posts == [.down(pt(10, 10), [])])   // a new gesture starts again
}

@Test func phaselessContinuousDuringPanDrops() {
    let m = Decide().make()
    let r = run(m, [sc(began), sc(0, 0, 2), sc(changed, 1, 0), sc(ended)])
    #expect(r.posts == [.down(pt(10, 10), []), .up(pt(10, 10), [])]); #expect(r.pass == [false, true, false, false])
}

@Test func phaselessContinuousAloneJustPasses() {
    let d = Decide(); let m = d.make()
    #expect(run(m, [sc(0, 0, 2), sc(0, 0, 2)]).pass == [true, true]); #expect(d.calls == 0)
}

@Test func watchdogReleasesAndResumes() {
    let m = Decide().make()
    _ = run(m, [sc(began, t: 0), sc(changed, 2, 0, t: 0.1)])
    let r = run(m, [.tick(2.2)])
    #expect(r.posts == [.up(pt(12, 10), [])]); #expect(m.state == .released(Target(pid: 500)))
    let s = run(m, [sc(changed, 1, 0, t: 3), sc(ended, t: 3.1)])
    #expect(s.posts == [.down(pt(12, 10), []), .drag(pt(13, 10), []), .up(pt(13, 10), [])])
}

@Test func tickBeforeTwoSecondsKeeps() {
    let m = Decide().make()
    _ = run(m, [sc(began, t: 0), sc(changed, 2, 0, t: 1)])
    #expect(run(m, [.tick(2.5)]).posts.isEmpty); #expect(m.state == .panning(Target(pid: 500)))
}

@Test func everyCancelReasonDropsTheRest() {
    for reason: CancelReason in [.tapDisabled, .permissionLost, .targetGone(500), .hittestFailed(500), .displays, .activated(77), .switchOff] {
        let m = Decide().make()
        _ = run(m, [sc(began), sc(changed, 1, 0)])
        let c = run(m, [.cancel(reason)])
        #expect(c.posts == [.up(pt(11, 10), [])], "\(reason)")
        let tail = run(m, [sc(changed, 1, 0), sc(ended), sc(0, 1, 0, momentum: 1), sc(0, 0, 0, momentum: 3)])
        #expect(tail.posts.isEmpty, "\(reason)"); #expect(tail.pass == [false, false, false, false], "\(reason)")
        #expect(run(m, [sc(began)]).posts == [.down(pt(10, 10), [])], "\(reason)")
    }
}

@Test func cancelOfAnotherRevitKeeps() {
    let m = Decide().make()
    _ = run(m, [sc(began)])
    #expect(run(m, [.cancel(.targetGone(501)), .cancel(.hittestFailed(501))]).posts.isEmpty)
    #expect(m.state == .panning(Target(pid: 500)))
}

@Test func activatedSamePidKeeps() {
    let m = Decide().make()
    _ = run(m, [sc(began)])
    #expect(run(m, [.cancel(.activated(500))]).posts.isEmpty); #expect(m.state == .panning(Target(pid: 500)))
}

@Test func twoRevitsActivatedOtherDrops() {
    let m = Decide().make()
    _ = run(m, [sc(began)])
    #expect(run(m, [.cancel(.activated(501))]).posts == [.up(pt(10, 10), [])]); #expect(m.state == .dropping)
    let p = Decide().make()
    _ = run(p, [mg(.began), mg(.changed, 0.01)])
    #expect(run(p, [.cancel(.activated(501))]).posts.isEmpty); #expect(p.state == .dropping)
    #expect(run(p, [mg(.changed, 0.01)]) == ([], [false]))
}

@Test func mouseDownDuringPanDrops() {
    let m = Decide().make()
    _ = run(m, [sc(began)])
    let r = run(m, [.mouseDown(ours: false), sc(changed, 1, 0)])
    #expect(r.posts == [.up(pt(10, 10), [])]); #expect(r.pass == [true, false]); #expect(m.state == .dropping)
}

@Test func ownMouseDownKeepsPanning() {
    let m = Decide().make()
    _ = run(m, [sc(began)])
    #expect(run(m, [.mouseDown(ours: true)]) == ([], [true])); #expect(m.state == .panning(Target(pid: 500)))
}

@Test func shiftFixedAtBegin() {
    let m = Decide().make()
    let r = run(m, [sc(began, mods: [.shift]), sc(changed, 1, 0, mods: []), sc(ended, mods: [.control])])
    #expect(r.posts == [.down(pt(10, 10), [.shift]), .drag(pt(11, 10), [.shift]), .up(pt(11, 10), [.shift])])
    let n = Decide().make()
    #expect(run(n, [sc(began), sc(changed, 1, 0, mods: [.shift])]).posts == [.down(pt(10, 10), []), .drag(pt(11, 10), [])])
}

@Test func pinchCarry() {
    let m = Decide().make()
    let r = run(m, [mg(.began), mg(.changed, 0.0010), mg(.changed, 0.0010), mg(.changed, -0.0050), mg(.ended)])
    #expect(r.posts == [.wheel(1, pt(10, 10)), .wheel(-2, pt(10, 10))])   // 0.6, 1.2 → 1 (0.2 left), 0.2 − 3.0 = −2.8 → −2
    #expect(r.pass == [false, false, false, false, false])
}

@Test func pinchResetsRemainder() {
    let m = Decide().make()
    _ = run(m, [mg(.began), mg(.changed, 0.0010), mg(.ended)])          // 0.6 left over
    #expect(run(m, [mg(.began), mg(.changed, 0.0010), mg(.ended)]).posts.isEmpty)
}

@Test func pinchDuringPanEndsPan() {
    let m = Decide().make()
    _ = run(m, [sc(began), sc(changed, 1, 0)])
    let r = run(m, [mg(.began), mg(.changed, 0.002)])
    #expect(r.posts == [.up(pt(11, 10), []), .wheel(1, pt(10, 10))]); #expect(m.state == .pinching(Target(pid: 500)))
}

@Test func scrollDuringPinchEndsPinch() {
    let m = Decide().make()
    _ = run(m, [mg(.began), mg(.changed, 0.001)])
    let r = run(m, [sc(began), sc(changed, 1, 0)])
    #expect(r.posts == [.down(pt(10, 10), []), .drag(pt(11, 10), [])]); #expect(m.state == .panning(Target(pid: 500)))
}

@Test func pinchWithoutBegan() {
    let d = Decide(); let m = d.make()
    #expect(run(m, [mg(.changed, 0.002), mg(.ended)]).posts == [.wheel(1, pt(10, 10))]); #expect(d.calls == 1)
}

@Test func decideNilPassesWholeGesture() {
    let d = Decide(); d.answer = nil; let m = d.make()
    let r = run(m, [sc(mayBegin), sc(began), sc(changed, 3, 3), sc(ended), mg(.began), mg(.changed, 0.1), mg(.ended)])
    #expect(r.posts.isEmpty); #expect(r.pass.allSatisfy { $0 })
}

@Test func oursAlwaysPasses() {
    let m = Decide().make()
    _ = run(m, [sc(began)])
    #expect(run(m, [sc(changed, 5, 5, ours: true), sc(0, 0, 3, continuous: false, ours: true)]) == ([], [true, true]))
    #expect(m.state == .panning(Target(pid: 500)))
}

@Test func displaysCancelDuringPinch() {
    let m = Decide().make()
    _ = run(m, [mg(.began)])
    #expect(run(m, [.cancel(.displays)]).posts.isEmpty); #expect(m.state == .dropping)
    #expect(run(m, [mg(.changed, 0.01), mg(.ended)]) == ([], [false, false]))
    #expect(m.state == .idle)
}

@Test func otherGesturesPass() {
    let m = Decide().make()
    _ = run(m, [sc(began)])
    #expect(run(m, [.otherGesture]) == ([], [true])); #expect(m.state == .panning(Target(pid: 500)))
}
