// The Mac window under a point: the first one that holds it, from front to back, must be Revit's.
import CoreGraphics
import Testing
@testable import TrackpadCore

let revit = WinInfo(pid: 500, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800), alpha: 1)
let p = CGPoint(x: 100, y: 100)

@Test func revitInFront() { #expect(WindowPick.target(at: p, frontToBack: [revit], revitPids: [500]) == 500) }
@Test func anotherAppInFront() {
    let panel = WinInfo(pid: 77, bounds: CGRect(x: 50, y: 50, width: 200, height: 200), alpha: 1)
    #expect(WindowPick.target(at: p, frontToBack: [panel, revit], revitPids: [500]) == nil)
}
@Test func transparentAndEmptyWindowsAreSkipped() {
    let clear = WinInfo(pid: 77, bounds: CGRect(x: 0, y: 0, width: 4000, height: 3000), alpha: 0)
    let empty = WinInfo(pid: 78, bounds: CGRect(x: 100, y: 100, width: 0, height: 0), alpha: 1)
    #expect(WindowPick.target(at: p, frontToBack: [clear, empty, revit], revitPids: [500]) == 500)
}
@Test func windowsElsewhereDoNotCount() {
    let far = WinInfo(pid: 77, bounds: CGRect(x: 2000, y: 0, width: 100, height: 100), alpha: 1)
    #expect(WindowPick.target(at: p, frontToBack: [far, revit], revitPids: [500]) == 500)
}
@Test func theCursorDoesNotCount() {   // a custom cursor (Revit's orbit cursor) is a window of its own at the point
    let cursor = WinInfo(pid: 608, bounds: CGRect(x: 95, y: 95, width: 32, height: 32), alpha: 1, layer: WindowPick.cursorLayer)
    #expect(WindowPick.target(at: p, frontToBack: [cursor, revit], revitPids: [500]) == 500)
}
@Test func anInvisibleFullDisplayWindowOfMacOSIsNotOverRevit() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let overlay = WinInfo(pid: 77, bounds: screen, alpha: 1, layer: 24, owner: "Screenshot", system: true)
    #expect(WindowPick.target(at: p, frontToBack: [overlay, revit], revitPids: [500], displays: [screen]) == 500)
    #expect(WindowPick.target(at: p, frontToBack: [overlay, revit], revitPids: [500]) == nil)   // displays unknown: as before
    let dock = WinInfo(pid: 78, bounds: CGRect(x: 0, y: 700, width: 1000, height: 100), alpha: 1, layer: 20, system: true)
    #expect(WindowPick.target(at: CGPoint(x: 100, y: 750), frontToBack: [dock, revit], revitPids: [500], displays: [screen]) == nil)
    let normal = WinInfo(pid: 79, bounds: screen, alpha: 1, layer: 0)   // a real window filling the screen stays over Revit
    #expect(WindowPick.target(at: p, frontToBack: [normal, revit], revitPids: [500], displays: [screen]) == nil)
    let app = WinInfo(pid: 80, bounds: screen, alpha: 1, layer: 24)     // another app's overlay may be a real one
    #expect(WindowPick.target(at: p, frontToBack: [app, revit], revitPids: [500], displays: [screen]) == nil)
}

@Test func anUnknownRevit() { #expect(WindowPick.target(at: p, frontToBack: [revit], revitPids: [501]) == nil) }
@Test func nothingThere() { #expect(WindowPick.target(at: CGPoint(x: 5000, y: 5000), frontToBack: [revit], revitPids: [500]) == nil) }
