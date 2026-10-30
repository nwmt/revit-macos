// FileOpenModel: what is asked and what the engine is told. No file ever goes to a Revit of another year unasked.
import Foundation
import Testing
@testable import AppCore

@MainActor final class FakeAsk: FileOpenAsking {
    var told: [String] = []
    var choices: [(format: Int, canAdd: Bool, copyTo: Int?, shared: Bool)] = []
    var bottle: String?
    var choice = FileChoice.cancel
    var added = 0
    func tell(file: String, _ text: String) { told.append(text) }
    func pickBottle(file: String, year: Int, bottles: [String]) -> String? { bottle }
    func choose(file: String, format: Int, canAdd: Bool, copyTo: Int?, shared: Bool) -> FileChoice {
        choices.append((format, canAdd, copyTo, shared)); return choice
    }
    func addRevit() { added += 1 }
}

@MainActor @Suite struct FileOpenModelTests {
    let url = URL(fileURLWithPath: "/m/a b.rvt")
    var dry: [String] { ["open", url.path, "--dry-run", "--json"] }

    func out(_ json: String, code: Int32 = 0, err: String = "") -> EngineOutput { EngineOutput(stdout: Data(json.utf8), stderr: err, exitCode: code) }
    func plan(_ action: String, format: String = "2025", share: String = "Not enabled", bottles: String = "[]", newer: String = "[]", add: Bool = false) -> EngineOutput {
        out(#"{"file":"x","format":\#(format),"worksharing":"\#(share)","error":"","size":1,"mtime_ns":2,"action":"\#(action)","year":2025,"bottles":\#(bottles),"newer":\#(newer),"can_add":\#(add),"say":"why"}"#)
    }
    func sends(_ e: FakeEngine) async -> [String] { await e.calls.filter { $0.hasPrefix("run open") && !$0.contains("--dry-run") } }

    func go(_ e: FakeEngine, _ a: FakeAsk) async {
        let m = FileOpenModel(engine: e, ask: a)
        await m.add([url]); await m.start()
    }

    @Test func itsOwnYearGoesToTheBottleTheEngineNamed() async {
        let e = FakeEngine(), a = FakeAsk()
        await e.set(query: dry, plan("open", bottles: #"[{"name":"rvt2025-a","running":true}]"#))
        await e.set(query: ["open", url.path, "--bottle", "rvt2025-a"], out(""))
        await go(e, a)
        #expect(await sends(e) == ["run open \(url.path) --bottle rvt2025-a"])
        #expect(a.told.isEmpty)
    }

    @Test func nothingHappensBeforeTheAppIsUp() async {
        let e = FakeEngine(), a = FakeAsk()
        await FileOpenModel(engine: e, ask: a).add([url])
        #expect(await e.calls.isEmpty)
    }

    @Test func aFailureShowsTheEnginesWords() async {
        let e = FakeEngine(), a = FakeAsk()
        await e.set(query: dry, plan("open", bottles: #"[{"name":"b"}]"#))
        await e.set(query: ["open", url.path, "--bottle", "b"], out("", code: 1, err: "Revit 2025 is busy.\n"))
        await go(e, a)
        #expect(a.told == ["Revit 2025 is busy."])
    }

    @Test func aMissingYearOpensNothingWhenCancelled() async {
        let e = FakeEngine(), a = FakeAsk()
        await e.set(query: dry, plan("choose", newer: #"[{"year":2027,"bottle":"rvt2027-a"}]"#, add: true))
        await go(e, a)
        #expect(a.choices.count == 1 && a.choices[0].format == 2025 && a.choices[0].canAdd && a.choices[0].copyTo == 2027)
        #expect(await sends(e).isEmpty)
    }

    @Test func addingRevitOpensTheWizardNotTheFile() async {
        let e = FakeEngine(), a = FakeAsk(); a.choice = .add
        await e.set(query: dry, plan("choose", add: true))
        await go(e, a)
        #expect(a.added == 1)
        #expect(await sends(e).isEmpty)
    }

    @Test func theCopyIsAskedForByItsYearAndBottle() async {
        let e = FakeEngine(), a = FakeAsk(); a.choice = .copy
        await e.set(query: dry, plan("choose", newer: #"[{"year":2026,"bottle":"x"},{"year":2027,"bottle":"y"}]"#))
        await e.set(query: ["open", url.path, "--copy-for", "2026", "--bottle", "x"], out(""))
        await go(e, a)
        #expect(await sends(e) == ["run open \(url.path) --copy-for 2026 --bottle x"])
    }

    @Test func aSharedModelGetsNoCopy() async {
        let e = FakeEngine(), a = FakeAsk(); a.choice = .copy
        await e.set(query: dry, plan("choose", share: "Central", newer: #"[{"year":2027,"bottle":"y"}]"#))
        await go(e, a)
        #expect(a.choices[0].copyTo == nil && a.choices[0].shared)
        #expect(await sends(e).isEmpty)
    }

    @Test func severalBottlesAsk() async {
        let e = FakeEngine(), a = FakeAsk(); a.bottle = "b"
        await e.set(query: dry, plan("pick_bottle", bottles: #"[{"name":"a"},{"name":"b"}]"#))
        await e.set(query: ["open", url.path, "--bottle", "b"], out(""))
        await go(e, a)
        #expect(await sends(e) == ["run open \(url.path) --bottle b"])
    }

    @Test func cancellingTheBottleOpensNothing() async {
        let e = FakeEngine(), a = FakeAsk()
        await e.set(query: dry, plan("pick_bottle", bottles: #"[{"name":"a"},{"name":"b"}]"#))
        await go(e, a)
        #expect(await sends(e).isEmpty)
    }

    @Test func anUnreadableFileIsOnlyExplained() async {
        let e = FakeEngine(), a = FakeAsk()
        await e.set(query: dry, plan("unreadable", format: "null"))
        await go(e, a)
        #expect(a.told == ["why"])
        #expect(await sends(e).isEmpty)
    }

    @Test func filesGoOneAtATime() async {
        let e = FakeEngine(), a = FakeAsk(), u2 = URL(fileURLWithPath: "/m/c.rvt")
        let m = FileOpenModel(engine: e, ask: a)
        for u in [url, u2] { await e.set(query: ["open", u.path, "--dry-run", "--json"], plan("unreadable")) }
        await m.add([url, u2]); await m.start()
        #expect(a.told.count == 2)
    }
}
