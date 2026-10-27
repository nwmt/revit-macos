// hittest.exe's protocol, version 1 (tools/shims/hittest/hittest.c).
import CoreGraphics
import Foundation
import Testing
@testable import TrackpadCore

@Test func helloReadsTheVirtualScreen() {
    #expect(HittestProtocol.hello("hello 1 0 0 3024 1964") == CGRect(x: 0, y: 0, width: 3024, height: 1964))
    #expect(HittestProtocol.hello("hello 1 -3840 0 6864 2160") == CGRect(x: -3840, y: 0, width: 6864, height: 2160))
}

@Test func helloRefusesOtherShapes() {
    #expect(HittestProtocol.hello("hello 1 0 0 3024") == nil)        // five fields
    #expect(HittestProtocol.hello("hello 2 0 0 3024 1964") == nil)   // another version
    #expect(HittestProtocol.hello("hullo 1 0 0 3024 1964") == nil)
    #expect(HittestProtocol.hello("hello 1 0 0 x 1964") == nil)
    #expect(HittestProtocol.hello("") == nil)
}

@Test func replyReadsTheChain() {
    let r = HittestProtocol.reply("7\tAfxFrameOrView140u\t\tAfxMDIFrame140u\tFloor Plan: L1\tTop\tAutodesk Revit 2027\t.")
    #expect(r == HitReply(seq: 7, chain: [HitWindow(cls: "AfxFrameOrView140u", title: ""),
                                          HitWindow(cls: "AfxMDIFrame140u", title: "Floor Plan: L1"),
                                          HitWindow(cls: "Top", title: "Autodesk Revit 2027")], complete: true, bad: false))
}

@Test func replyCutChainNoWindowAndBadLine() {
    #expect(HittestProtocol.reply("8\tDeep\t\t+") == HitReply(seq: 8, chain: [HitWindow(cls: "Deep", title: "")], complete: false, bad: false))
    #expect(HittestProtocol.reply("9\t.") == HitReply(seq: 9, chain: [], complete: true, bad: false))
    #expect(HittestProtocol.reply("0\t?") == HitReply(seq: 0, chain: [], complete: false, bad: true))
    #expect(HittestProtocol.reply("5\tA\ta title with spaces\t.")?.chain == [HitWindow(cls: "A", title: "a title with spaces")])
}

@Test func replyRefusesMalformedLines() {
    #expect(HittestProtocol.reply("7\tAfxFrameOrView140u\t.") == nil)   // a class without its title
    #expect(HittestProtocol.reply("x\t.") == nil)
    #expect(HittestProtocol.reply("7\tA\tb") == nil)                    // no end mark
    #expect(HittestProtocol.reply("") == nil)
}

@Test func requestLine() {
    #expect(HittestProtocol.request(seq: 3, x: -10, y: 20) == "3 -10 20\n")
}

@Test func lineBufferJoinsAndSplits() {
    var b = LineBuffer()
    #expect(b.append(Data("hel".utf8)) == [])
    #expect(b.append(Data("lo\nab\ncd".utf8)) == [.line("hello"), .line("ab")])
    #expect(b.append(Data("\n".utf8)) == [.line("cd")])
}

@Test func lineBufferOverflowWithoutNewline() {
    var b = LineBuffer()
    #expect(b.append(Data(repeating: 57, count: 4097)) == [.overflow])
    #expect(b.append(Data(repeating: 57, count: 100)) == [])          // still the same long line
    #expect(b.append(Data("\nok\n".utf8)) == [.line("ok")])
}

@Test func lineBufferOverflowWithNewlineWholeAndInParts() {
    var b = LineBuffer()
    #expect(b.append(Data(repeating: 56, count: 5000) + Data("\nnext\n".utf8)) == [.overflow, .line("next")])
    var c = LineBuffer()
    #expect(c.append(Data(repeating: 56, count: 3000)) == [])
    #expect(c.append(Data(repeating: 56, count: 2000) + Data("\n".utf8)) == [.overflow])
    #expect(c.append(Data("next\n".utf8)) == [.line("next")])
}
