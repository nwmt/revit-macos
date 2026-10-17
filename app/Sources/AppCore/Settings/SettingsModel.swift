// Settings (spec §3): open at login, the daily update check, the installer files the engine can delete.
import Foundation
import Observation

/// SMAppService.Status, as the settings need it.
public enum LoginStatus: Equatable, Sendable { case enabled, disabled, needsApproval, unavailable }

@MainActor public protocol LoginItem {
    var status: LoginStatus { get }
    func set(_ on: Bool) throws
}

/// revit cache --json.
public struct CachePlan: Decodable, Equatable, Sendable {
    public let items: [CacheItem]
    public let removableBytes: Int64
}

public struct CacheItem: Decodable, Equatable, Sendable {
    public let what: String                 // downloads, extracted, winetricks
    public let year: Int?
    public let label: String
    public let bytes: Int64
    public let removable: Bool
    public let kept: String                 // why it stays ("bottle rvt2025-a uses it", "your installer folder")
}

@MainActor @Observable public final class SettingsModel {
    @ObservationIgnored let app: AppModel
    @ObservationIgnored let login: any LoginItem
    @ObservationIgnored let updates: UpdateChecker
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let name: String
    public private(set) var loginError: String?
    public private(set) var cache: CachePlan?
    public private(set) var cacheError: String?
    private var loginTick = 0          // re-read the login status after a change

    public init(app: AppModel, login: any LoginItem, updates: UpdateChecker, defaults: UserDefaults,
                name: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "") {
        self.app = app; self.login = login; self.updates = updates; self.defaults = defaults; self.name = name
    }

    public var launchAtLogin: Bool {
        get { _ = loginTick; return login.status == .enabled || login.status == .needsApproval }
        set {
            do { try login.set(newValue); loginError = nil } catch { loginError = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            loginTick += 1
        }
    }

    public var loginNote: String? {
        _ = loginTick
        switch login.status {
        case .needsApproval: return String(localized: "Allow it in System Settings → General → Login Items.")
        case .unavailable: return String(localized: "Open at login works only for the app in the Applications folder.")
        default: return nil
        }
    }

    public var checkForUpdates: Bool {
        get { defaults.object(forKey: "checkForUpdates") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "checkForUpdates") }
    }

    public func loadCache() async {
        guard let out = await app.query(["cache", "--json"]) else { cacheError = app.engineError; return }
        guard out.exitCode == 0, let p = try? JSONDecoder.engine.decode(CachePlan.self, from: out.stdout) else {
            cacheError = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines); return
        }
        cache = p; cacheError = nil
    }

    public func clearCache() async {
        guard let out = await app.query(["cache", "clear", "--yes"]) else { cacheError = app.engineError; return }
        await loadCache()
        if out.exitCode != 0 { cacheError = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Once a day, when on: a newer release becomes one notification. A network error is silent; tomorrow tries again.
    public func checkUpdatesIfDue(now: Date) async {
        guard checkForUpdates, UpdateChecker.due(last: defaults.object(forKey: "lastUpdateCheck") as? Date, now: now) else { return }
        defaults.set(now, forKey: "lastUpdateCheck")
        guard let r = try? await updates.newer() else { return }
        app.notifier.post(title: String(localized: "\(name) \(r.version) is available"),
                          body: String(localized: "Download it from the project's releases."), url: r.url)
    }
}
