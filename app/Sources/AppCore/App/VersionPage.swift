// What the version page shows, without a screen: its tabs, the line about fixes, the drafts of its two Apply buttons.
// The profile decides through status --json: a tab shows only when the year has its steps.
import Foundation

public enum VersionTab: String, CaseIterable, Hashable, Sendable {
    case overview, display, drive, addins, ai, maintenance

    public static func of(_ b: Bottle?) -> [VersionTab] {
        let s = b?.settings ?? [:]
        return allCases.filter {
            switch $0 {
            case .display: SettingsDraft.keys.contains { s[$0] != nil }
            case .drive: s["gdrive"] != nil
            default: true
            }
        }
    }
}

/// A restore point's time as the Mac writes dates; the engine's text when it is not a date.
public enum PointTime {
    public static func text(_ iso: String) -> String {
        (try? Date(iso, strategy: .iso8601))?.formatted(date: .abbreviated, time: .shortened) ?? iso
    }
}

public enum StatusWords {
    public static func of(_ status: String?) -> String {
        switch status {
        case "works": String(localized: "Works")
        case "mostly": String(localized: "Mostly works")
        default: String(localized: "Not tested")
        }
    }
}

public enum FixesLine: Equatable, Sendable {
    case unknown, built(String), newer(built: String, now: String)

    public static func of(built: Built?, now: String?) -> FixesLine {
        guard let b = built, !b.shims.isEmpty else { return .unknown }
        if let n = now, let x = number(n), let y = number(b.shims), y.lexicographicallyPrecedes(x) { return .newer(built: b.shims, now: n) }
        return .built(b.shims)
    }

    /// 0.15.0 as numbers; source:… and unknown are no release and are not compared.
    static func number(_ s: String) -> [Int]? {
        let p = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard p.count == 3, !p.contains(where: { $0 == nil }) else { return nil }
        return p.compactMap { $0 }
    }
}

/// Display & Keys: what the bottle has and what is picked; Apply sends only what changed.
public struct SettingsDraft: Equatable, Sendable {
    public static let keys = ["retina", "keys", "theme", "steel"]
    /// The price of steel=off, as the engine and versions/<year>.md state it.
    public static func steelCost(year: Int) -> String {
        if year == 2020 {
            return String(localized: "On: Revit closes when it draws a view with steel connections. Off: such views open, but the steel connection tools are gone.")
        }
        return String(localized: "On: models with links wait 1 to 3 minutes on first open. Off: they open faster, but the steel connection tools are gone, and 1 of 7 models tried stopped with a serious error while opening.")
    }

    public let original: [String: String]
    public var picked: [String: String]

    public init(_ settings: [String: String]) {
        original = settings.filter { Self.keys.contains($0.key) }
        picked = original
    }

    /// retina, keys, steel with a value the buttons cannot show (mixed, "") show no selection.
    public var changes: [String] {
        Self.keys.compactMap { k in
            guard let v = picked[k], v != original[k], Self.options(k).contains(v) else { return nil }
            return "\(k)=\(v)"
        }
    }

    public static func options(_ key: String) -> [String] {
        switch key {
        case "retina": ["on", "compact", "off"]
        case "keys": ["mac", "windows"]
        case "theme": ["mac", "light", "dark"]
        case "steel": ["on", "off"]
        default: []
        }
    }

    public var needsSteelConfirm: Bool { changes.contains("steel=off") }

    public func canApply(running: Bool, busy: Bool) -> Bool { !changes.isEmpty && !running && !busy }
}

/// Google Drive: the address is typed only when moving to Account, and never kept here after Apply.
public struct GDriveDraft: Equatable, Sendable {
    public let mode: String
    public let namesKind: String
    public var picked: String
    public var email = ""
    public var russian: Bool

    public init(_ s: GDriveState?) {
        mode = s?.mode ?? "auto"; namesKind = s?.namesKind ?? "en"; picked = mode; russian = namesKind == "ru"
    }

    public var showsNames: Bool { namesKind != "custom" }
    public var needsEmail: Bool { picked == "account" }
    var emailOK: Bool { email.wholeMatch(of: /[^\s@]+@[^\s@]+\.[^\s@]+/) != nil }

    public var changes: [String] {
        var c: [String] = []
        if picked == "account" {
            if emailOK { c.append("gdrive=\(email)") }
        } else if picked != mode { c.append("gdrive=\(picked)") }
        if showsNames, russian != (namesKind == "ru") { c.append("gdrive_names=\(russian ? "ru" : "en")") }
        return c
    }

    public func canApply(running: Bool, busy: Bool) -> Bool {
        !changes.isEmpty && !running && !busy && (picked != "account" || mode == "account" || emailOK)
    }
}

/// Which window a launch opens: the first rule that holds.
public enum LaunchRoute: Equatable, Sendable {
    case activity, addVersion, main, nothing

    public static func pick(activeRun: Bool, forFile: Bool, loginItem: Bool, noBottles: Bool, busy: Bool, showInDock: Bool) -> LaunchRoute {
        if activeRun { return .activity }
        if forFile { return .nothing }
        if noBottles && !busy && !loginItem { return .addVersion }
        if loginItem || !showInDock { return .nothing }
        return .main
    }
}
