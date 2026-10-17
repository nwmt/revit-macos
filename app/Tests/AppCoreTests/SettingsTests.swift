// Settings: open at login, the daily update check against the project's GitHub releases, the installer cache.
import Foundation
import Testing
@testable import AppCore

@MainActor final class FakeLogin: LoginItem {
    var status: LoginStatus = .disabled
    var error: String?
    var sets: [Bool] = []
    func set(_ on: Bool) throws {
        sets.append(on)
        if let error { throw FakeError(text: error) }
        status = on ? .enabled : .disabled
    }
}

actor Fetches {
    var urls: [URL] = []
    func add(_ u: URL) { urls.append(u) }
}

let releasesJSON = """
[{"tag_name":"v0.7.0","draft":false,"prerelease":false,"html_url":"https://github.com/o/r/releases/tag/v0.7.0"},
 {"tag_name":"app-v0.2.0","draft":true,"prerelease":true,"html_url":"https://github.com/o/r/releases/tag/app-v0.2.0"},
 {"tag_name":"app-v0.1.1","draft":false,"prerelease":true,"html_url":"https://github.com/o/r/releases/tag/app-v0.1.1"},
 {"tag_name":"app-v0.1.0","draft":false,"prerelease":true,"html_url":"https://github.com/o/r/releases/tag/app-v0.1.0"}]
"""

func checker(current: String = "0.1.0", body: String = releasesJSON, fails: Bool = false, log: Fetches = Fetches()) -> UpdateChecker {
    UpdateChecker(repo: "o/r", current: current) { url in
        await log.add(url)
        if fails { throw URLError(.notConnectedToInternet) }
        return Data(body.utf8)
    }
}

@MainActor final class SettingsHarness {
    let h = Harness()
    let login = FakeLogin()
    let fetches = Fetches()
    lazy var settings = SettingsModel(app: h.model, login: login, updates: checker(log: fetches), defaults: h.defaults, name: "Test App")
}

@MainActor @Suite(.serialized) struct SettingsTests {
    @Test func isNewerComparesNumbers() {
        #expect(UpdateChecker.isNewer("0.1.10", than: "0.1.9")); #expect(UpdateChecker.isNewer("1.0.0", than: "0.9.9"))
        #expect(!UpdateChecker.isNewer("0.1.0", than: "0.1.0")); #expect(!UpdateChecker.isNewer("0.1", than: "0.0.1"))
        #expect(!UpdateChecker.isNewer("v0.2.0", than: "0.1.0")); #expect(!UpdateChecker.isNewer("0.0.9", than: "0.1.0"))
    }

    @Test func newerPicksTheHighestAppRelease() async throws {
        let log = Fetches()
        let r = try await checker(log: log).newer()
        #expect(r == Release(version: "0.1.1", url: URL(string: "https://github.com/o/r/releases/tag/app-v0.1.1")!))
        #expect(await log.urls == [URL(string: "https://api.github.com/repos/o/r/releases?per_page=30")!])
    }

    @Test func noneNewerIsNil() async throws { #expect(try await checker(current: "0.1.1").newer() == nil) }

    @Test func dueOncePerDay() {
        let now = Date()
        #expect(UpdateChecker.due(last: nil, now: now))
        #expect(!UpdateChecker.due(last: now.addingTimeInterval(-23 * 3600), now: now))
        #expect(UpdateChecker.due(last: now.addingTimeInterval(-25 * 3600), now: now))
    }

    @Test func checkUpdatesIfDuePostsOnceAndRecordsTheDate() async {
        let s = SettingsHarness()
        #expect(s.settings.checkForUpdates)
        let now = Date()
        await s.settings.checkUpdatesIfDue(now: now)
        #expect(s.h.notifier.posts.count == 1)
        #expect(s.h.notifier.posts.first?.title == "Test App 0.1.1 is available")
        #expect(s.h.notifier.posts.first?.url == URL(string: "https://github.com/o/r/releases/tag/app-v0.1.1"))
        #expect(s.h.defaults.object(forKey: "lastUpdateCheck") as? Date == now)
        await s.settings.checkUpdatesIfDue(now: now.addingTimeInterval(3600))
        #expect(await s.fetches.urls.count == 1); #expect(s.h.notifier.posts.count == 1)
    }

    @Test func disabledNoFetch() async {
        let s = SettingsHarness()
        s.settings.checkForUpdates = false
        #expect(s.h.defaults.bool(forKey: "checkForUpdates") == false)
        await s.settings.checkUpdatesIfDue(now: Date())
        #expect(await s.fetches.urls.isEmpty)
    }

    @Test func aFetchErrorIsSilent() async {
        let h = Harness()
        let s = SettingsModel(app: h.model, login: FakeLogin(), updates: checker(fails: true), defaults: h.defaults, name: "Test App")
        await s.checkUpdatesIfDue(now: Date())
        #expect(h.notifier.posts.isEmpty)
    }

    @Test func loginToggleCallsTheItemAndKeepsItsError() {
        let s = SettingsHarness()
        #expect(!s.settings.launchAtLogin)
        s.settings.launchAtLogin = true
        #expect(s.login.sets == [true]); #expect(s.settings.launchAtLogin); #expect(s.settings.loginError == nil)
        s.login.error = "Operation not permitted"
        s.settings.launchAtLogin = false
        #expect(s.settings.loginError == "Operation not permitted"); #expect(s.settings.launchAtLogin)
    }

    @Test func loginNeedsApprovalIsOnWithTheNote() {
        let s = SettingsHarness()
        s.login.status = .needsApproval
        #expect(s.settings.launchAtLogin); #expect(s.settings.loginNote == "Allow it in System Settings → General → Login Items.")
    }

    @Test func loginUnavailableIsOffWithTheNote() {
        let s = SettingsHarness()
        s.login.status = .unavailable
        #expect(!s.settings.launchAtLogin); #expect(s.settings.loginNote != nil)
    }

    @Test func cacheLoadsAndClearsWithTheExactArgs() async {
        let s = SettingsHarness()
        let plan = #"{"items":[{"what":"extracted","year":2025,"label":"installers/extracted/revit2025 (unpacked files)","bytes":2048,"removable":true,"kept":""},{"what":"winetricks","year":null,"label":"cache/winetricks (winetricks downloads)","bytes":10,"removable":true,"kept":""}],"removable_bytes":2058}"#
        await s.h.fake.set(query: ["cache", "--json"], EngineOutput(stdout: Data(plan.utf8), stderr: "", exitCode: 0))
        await s.h.fake.set(query: ["cache", "clear", "--yes"], EngineOutput(stdout: Data("Freed 0.0 GB.\n".utf8), stderr: "", exitCode: 0))
        await s.settings.loadCache()
        #expect(s.settings.cache?.removableBytes == 2058); #expect(s.settings.cache?.items.last?.year == nil)
        await s.settings.clearCache()
        let runs = await s.h.fake.calls.filter { $0.hasPrefix("run cache") }
        #expect(runs == ["run cache --json", "run cache clear --yes", "run cache --json"])
    }
}
