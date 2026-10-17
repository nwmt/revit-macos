// The contract between the Swift models and the real engine (the revit of this repo), run in a sandbox: a temporary
// HOME, data folder, lock folder and no CrossOver unless a test makes a fake one. No Revit, no network.
import Foundation
import Testing
@testable import AppCore

/// The repo's own revit, found from this file.
let repoEngine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appending(path: "revit")

@Suite(.serialized) struct EngineContractTests {
    let root = tempDir()

    /// The folder of 7zz (the engine reads a Create Installer with it); python3 comes from /usr/bin.
    func sevenZipFolder() throws -> String {
        let d = ["/opt/homebrew/bin", "/usr/local/bin"].first { FileManager.default.isExecutableFile(atPath: "\($0)/7zz") }
        let found = try #require(d, "7zz not found: brew install sevenzip")
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "/usr/bin/python3 is needed")
        return found
    }

    func env(cx: Bool = false) throws -> [String: String] {
        var e = TestEnv.make(root: root, extraPath: try sevenZipFolder())
        if cx { e["REVIT_CX"] = fakeCrossOver().path }
        return e
    }

    func engine(cx: Bool = false) throws -> ProcessEngine { ProcessEngine(engine: repoEngine, environment: try env(cx: cx)) }

    /// root/CrossOver.app with bin/cxbottle and bin/wineserver exiting 0 and version 26.3.0.
    func fakeCrossOver() -> URL {
        let app = root.appending(path: "CrossOver.app/Contents"); let cx = app.appending(path: "SharedSupport/CrossOver")
        let bin = cx.appending(path: "bin")
        try! FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for t in ["cxbottle", "wineserver"] {
            let f = bin.appending(path: t)
            try! Data("#!/bin/bash\nexit 0\n".utf8).write(to: f)
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
        try! Data(#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>26.3.0</string></dict></plist>"#.utf8)
            .write(to: app.appending(path: "Info.plist"))
        return cx
    }

    func makeBottle(_ name: String, year: Int) {
        let b = root.appending(path: "home/Library/Application Support/CrossOver/Bottles/\(name)")
        try! FileManager.default.createDirectory(at: b.appending(path: "drive_c"), withIntermediateDirectories: true)
        try! Data("[Bottle]\n\"Description\" = \"Revit \(year)\"\n".utf8).write(to: b.appending(path: "cxbottle.conf"))
    }

    func status(_ e: ProcessEngine) async throws -> EngineStatus {
        let out = try await e.run(["status", "--json"])
        #expect(out.exitCode == 0, "\(out.stderr)")
        return try EngineStatus.decode(out.stdout)
    }

    @Test func statusDecodesFromTheRealEngine() async throws {
        let s = try await status(try engine())
        #expect(!s.crossover.found); #expect(!s.crossover.supported); #expect(!s.msls31)
        #expect(s.bottles.isEmpty); #expect(!s.busy.busy); #expect(s.app == nil)
    }

    @Test func statusSeesABottleAndMsls31() async throws {
        makeBottle("rvt2025-a", year: 2025)
        let ms = root.appending(path: "data/installers/redist/win7sp1/x64")
        try FileManager.default.createDirectory(at: ms, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: ms.appending(path: "msls31.dll").path, contents: Data("x".utf8))
        let s = try await status(try engine())
        #expect(s.bottles.map(\.name) == ["rvt2025-a"]); #expect(s.bottles.first?.year == "2025")
        #expect(s.bottles.first?.revit == false); #expect(s.msls31)
    }

    @Test func findInstallerDecodes() async throws {
        let src = root.appending(path: "ci"), inst = root.appending(path: "Revit Installer")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inst, withIntermediateDirectories: true)
        try Data("<C><BrowserImageUrl>https://dds.autodesk.com/x/RVT_2025_B_002_002.7z</BrowserImageUrl></C>".utf8)
            .write(to: src.appending(path: "collection.xml"))
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = src
        zip.arguments = ["-q", inst.appending(path: "Create_Installer_RVT_2025_5_English_WIN64.exe").path, "collection.xml"]
        try zip.run(); zip.waitUntilExit(); #expect(zip.terminationStatus == 0)
        let out = try await engine().run(["find-installer", inst.path, "--json"])
        #expect(out.exitCode == 0, "\(out.stderr)")
        let i = try JSONDecoder.engine.decode(InstallerInfo.self, from: out.stdout)
        #expect(i.year == "2025"); #expect(i.kind == "create-installer"); #expect(i.downloadable)
    }

    @Test func addinsListDecodes() async throws {
        let out = try await engine().run(["addins", "list", "2025", "--json"])
        #expect(out.exitCode == 0, "\(out.stderr)")
        let a = try JSONDecoder.engine.decode([AddinInfo].self, from: out.stdout)
        let ids = Set(a.map(\.id))
        #expect(ids.isSuperset(of: ["pyrevit", "revitlookup", "pdfprinter"]))
        let py = try #require(a.first { $0.id == "pyrevit" })
        #expect(py.source == "auto"); #expect(py.ready)
        #expect(a.first { $0.id == "enscape" }?.available == false)
    }

    @Test func checkEventsReplay() async throws {
        let ctx = root.appending(path: "data/logs/runs/check-1")
        try FileManager.default.createDirectory(at: ctx, withIntermediateDirectories: true)
        let e = try engine()
        let pid = try await e.start(["check", "2025", "rvt2025-a"], ctx: ctx)
        defer { killGroup(pid) }
        var reader = NDJSONReader(url: ctx.appending(path: "events.ndjson"))
        var events: [EngineEvent] = []
        let ended = await waitFor(20) {
            events += (try? reader.readNew()) ?? []
            return events.contains { if case .end = $0 { return true }; return false }
        }
        #expect(ended, "no end event in 20 s: \(text(ctx.appending(path: "console.log")))")
        let s = RunState.replay(events)
        #expect(s.command == "check"); #expect(s.messages.contains { $0.level == "error" })
        #expect(s.end?.kind == .failed); #expect(s.end?.exitCode == 1); #expect(reader.malformed == 0)
    }

    @Test func removeDryRunDecodes() async throws {
        makeBottle("rvt2025-a", year: 2025)
        let e = try engine(cx: true)
        let out = try await e.run(["remove", "2025", "--dry-run", "--json"])
        #expect(out.exitCode == 0, "\(out.stderr)")
        let p = try JSONDecoder.engine.decode(RemovePlan.self, from: out.stdout)
        #expect(p.delete.first?.label == "bottle rvt2025-a"); #expect(p.notes.count == 2); #expect(p.nothing == false)
        try FileManager.default.removeItem(at: root.appending(path: "home/Library/Application Support/CrossOver/Bottles/rvt2025-a"))
        let none = try JSONDecoder.engine.decode(RemovePlan.self, from: try await e.run(["remove", "2025", "--dry-run", "--json"]).stdout)
        #expect(none.nothing == true); #expect(none.delete.isEmpty)
    }

    @Test func reportJSONDecodes() async throws {
        let out = try await engine().run(["report", "--json"])
        let r = try JSONDecoder.engine.decode(ReportResult.self, from: out.stdout)
        #expect(r.refused == nil, "\(out.stderr)")
        let txt = try #require(r.reportTxt)
        #expect(FileManager.default.fileExists(atPath: txt))
        #expect(txt.hasPrefix(root.appending(path: "data/logs/mac/").path))
    }

    @Test func aLockHeldByAChildAfterItsSupervisorDiedIsStillBusy() async throws {
        let e = try engine()
        let lock = root.appending(path: "lock/lock")
        // the "supervisor": a process that has ended, with its recorded start
        let gone = Process(); gone.executableURL = URL(fileURLWithPath: "/bin/sleep"); gone.arguments = ["0.5"]
        try gone.run()
        let start = try #require(await e.processStart(pid: gone.processIdentifier))
        gone.waitUntilExit()
        // the "child" that kept fd 9: holds the flock
        let holder = Process(); holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-MFcntl=:flock", "-e", "open(my $f, '>>', $ARGV[0]) or die; flock($f, LOCK_EX) or die; sleep 60", lock.path]
        try holder.run(); defer { holder.terminate() }
        try Data("command=install.sh 2025 rvt2025-a\nrun_id=r1\npid=\(gone.processIdentifier)\npid_start=\(start)\npgid=\(gone.processIdentifier)\nctx=/x\n".utf8)
            .write(to: root.appending(path: "lock/lock.owner"))
        var s = try await status(e)
        for _ in 0..<50 where !s.busy.busy { try await Task.sleep(for: .milliseconds(100)); s = try await status(e) }   // the holder takes the lock
        #expect(s.busy.busy); #expect(s.busy.runId == "r1")
        let pid = try #require(s.busy.pidNumber)
        #expect(await e.processStart(pid: pid) == nil)
    }
}

