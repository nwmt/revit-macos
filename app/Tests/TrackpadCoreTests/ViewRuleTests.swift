// Which Windows window counts as a Revit view: closed by default (checked years only).
import Testing
@testable import TrackpadCore

func reply(_ chain: [(String, String)], complete: Bool = true) -> HitReply {
    HitReply(seq: 1, chain: chain.map { HitWindow(cls: $0.0, title: $0.1) }, complete: complete, bad: false)
}
let plan = reply([("AfxFrameOrView140u", ""), ("AfxMDIFrame140u", "Floor Plan: L1"), ("Top", "Autodesk Revit 2027")])

@Test func aViewOf2027() { #expect(ViewRule.isView(year: 2027, reply: plan)) }
@Test func aViewOf2020() {
    #expect(ViewRule.isView(year: 2020, reply: reply([("AfxFrameOrView140u", ""), ("AfxMDIFrame140u", "Floor Plan: Level 1"),
                                                     ("Afx:0000000140000000:40", "Autodesk Revit 2020.2")])))
}
@Test func anUncheckedYear() { #expect(!ViewRule.isView(year: 2026, reply: plan)) }
@Test func aScheduleAtAnyLevel() {
    #expect(!ViewRule.isView(year: 2027, reply: reply([("AfxFrameOrView140u", ""), ("A", "x"), ("B", "Schedule: S")])))
}
@Test func aCutChain() {
    #expect(!ViewRule.isView(year: 2027, reply: reply([("AfxFrameOrView140u", ""), ("A", "Floor Plan: L1")], complete: false)))
}
@Test func noTitleAnywhere() { #expect(!ViewRule.isView(year: 2027, reply: reply([("AfxFrameOrView140u", ""), ("A", "")]))) }
@Test func anotherClass() {
    #expect(!ViewRule.isView(year: 2027, reply: reply([("GXWND", ""), ("A", "Properties")])))
    #expect(!ViewRule.isView(year: 2027, reply: reply([])))
    #expect(!ViewRule.isView(year: 2027, reply: HitReply(seq: 0, chain: [], complete: false, bad: true)))
}
