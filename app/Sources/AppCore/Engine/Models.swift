// The engine's JSON answers: status --json, find-installer --json, addins list --json, report --json and the
// remove/rebuild --dry-run --json plans. Keys are the engine's (snake_case); keys this app does not know are ignored.
// status writes the owner's numbers and the bottle's year as strings: kept as written, with typed views.
import Foundation

extension JSONDecoder {
    /// A decoder for the engine's snake_case keys.
    public static var engine: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}

public struct EngineStatus: Decodable, Equatable, Sendable {
    public let crossover: CrossOver
    public let rosetta: Bool
    public let msls31: Bool
    public let busy: Busy
    public let app: AppInfo?               // only inside the app's bundle
    public let bottles: [Bottle]

    public static func decode(_ data: Data) throws -> EngineStatus { try JSONDecoder.engine.decode(EngineStatus.self, from: data) }
}

public struct CrossOver: Decodable, Equatable, Sendable {
    public let found: Bool
    public let path: String
    public let version: String
    public let supported: Bool              // its major version is the one the status words were earned on
}

/// lock.owner of the task that holds the lock; every field "" when nobody does.
public struct Busy: Decodable, Equatable, Sendable {
    public let busy: Bool
    public let command, runId, pid, pidStart, pgid, ctx: String
    public var pidNumber: Int32? { Int32(pid) }
    public var pgidNumber: Int32? { Int32(pgid) }
}

public struct AppInfo: Decodable, Equatable, Sendable {
    public let name, version, path, placement, data: String
}

public struct Bottle: Decodable, Equatable, Sendable {
    public let name: String
    public let year: String
    public let revit: Bool                  // Revit.exe is there
    public let running: Bool
    public let revitPids: [Int32]           // the Mac processes of its Revit.exe; [] from an engine without the key
    public let addins: [String]
    public let steel: String                // where Steel Connections' manifests are: on, off, mixed, missing, none; "" unknown
    public let themeMode: String            // the step theme's mode: mac, light, dark; "" without it or from an older engine
    public var yearNumber: Int? { Int(year) }

    public init(name: String, year: String, revit: Bool, running: Bool, revitPids: [Int32] = [], addins: [String],
                themeMode: String = "", steel: String = "") {
        self.name = name; self.year = year; self.revit = revit; self.running = running; self.revitPids = revitPids
        self.addins = addins; self.themeMode = themeMode; self.steel = steel
    }

    enum CodingKeys: String, CodingKey { case name, year, revit, running, revitPids, addins, themeMode, steel }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name), year: try c.decode(String.self, forKey: .year),
                  revit: try c.decode(Bool.self, forKey: .revit), running: try c.decode(Bool.self, forKey: .running),
                  revitPids: try c.decodeIfPresent([Int32].self, forKey: .revitPids) ?? [],
                  addins: try c.decode([String].self, forKey: .addins),
                  themeMode: try c.decodeIfPresent(String.self, forKey: .themeMode) ?? "",
                  steel: try c.decodeIfPresent(String.self, forKey: .steel) ?? "")
    }
}

public struct InstallerInfo: Decodable, Equatable, Sendable {
    public let year: String?
    public let kind: String?                // create-installer, parts, archive, updates-only
    public let complete: Bool
    public let downloadable: Bool
    public let missing: [String]
    public let problem: String
    public let files: [InstallerFile]
}

public struct InstallerFile: Decodable, Equatable, Sendable {
    public let name: String
    public let check: String                // known | unknown | mismatch
}

public struct AddinInfo: Decodable, Equatable, Sendable {
    public let id, name, about: String
    public let available, installed, tested: Bool
    public let source, eula, tool: String
    public let toolOk: Bool
    public let ready: Bool
    public let notice: String               // shown before consent (the catalog's ADDIN_NOTICE); "" when the key is absent

    public init(id: String, name: String, about: String, available: Bool, installed: Bool, tested: Bool, source: String,
                eula: String, tool: String, toolOk: Bool, ready: Bool, notice: String = "") {
        self.id = id; self.name = name; self.about = about; self.available = available; self.installed = installed
        self.tested = tested; self.source = source; self.eula = eula; self.tool = tool; self.toolOk = toolOk
        self.ready = ready; self.notice = notice
    }

    enum CodingKeys: String, CodingKey { case id, name, about, available, installed, tested, source, eula, tool, toolOk, ready, notice }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  about: try c.decode(String.self, forKey: .about), available: try c.decode(Bool.self, forKey: .available),
                  installed: try c.decode(Bool.self, forKey: .installed), tested: try c.decode(Bool.self, forKey: .tested),
                  source: try c.decode(String.self, forKey: .source), eula: try c.decode(String.self, forKey: .eula),
                  tool: try c.decode(String.self, forKey: .tool), toolOk: try c.decode(Bool.self, forKey: .toolOk),
                  ready: try c.decode(Bool.self, forKey: .ready),
                  notice: try c.decodeIfPresent(String.self, forKey: .notice) ?? "")
    }
}

public struct ReportResult: Decodable, Equatable, Sendable {
    public let reportTxt, reportZip: String?
    public let summary: String?
    public let refused: String?             // why no report was made
}

/// What remove or rebuild would delete (--dry-run --json).
public struct RemovePlan: Decodable, Equatable, Sendable {
    public let command: String
    public let year: Int
    public let bottle: String
    public let nothing: Bool?               // remove only
    public let delete: [PlanItem]
    public let kept: [String]?              // remove only
    public let addinsReset: Bool?           // rebuild only
    public let restorePoint: Bool?          // rebuild only: the run keeps a restore point; false from an older engine is nil
    public let notes: [String]
}

public struct PlanItem: Decodable, Equatable, Sendable {
    public let label: String
    public let bytes: Int64?                // nil: not measured (apps)
}

/// cleanup --json (tools/leftovers.py): the programs left running, the bottles left alone because Revit runs there, and
/// after a close the PIDs that ended and those still running.
public struct CleanupReport: Decodable, Equatable, Sendable {
    public let items: [Leftover]
    public let skipped: [SkippedBottle]
    public let closed: [Int32]?             // close only
    public let left: [Int32]?               // close only

    public init(items: [Leftover], skipped: [SkippedBottle], closed: [Int32]? = nil, left: [Int32]? = nil) {
        self.items = items; self.skipped = skipped; self.closed = closed; self.left = left
    }

    /// The lines of Close all's confirmation: one per program, then the warning when Revit is among them.
    public var planLines: [String] {
        items.map(\.line) + (items.contains(where: \.revit)
            ? [String(localized: "Revit closes without saving: unsaved changes are lost.")] : [])
    }
}

public struct Leftover: Decodable, Equatable, Sendable {
    public let pid: Int32
    public let kind: String                 // wine, helper, gdrive
    public let reason: String               // no_wineserver, bottle_gone, parent_gone, stuck; all (--all)
    public let bottle: String?
    public let name: String
    public let cpu: Double
    public let ageS: Int
    public let start: Int64                 // the process's start (microseconds since 1970): with pid, the process approved
    public let revit: Bool                  // Revit.exe: it closes without saving

    public init(pid: Int32, kind: String, reason: String, bottle: String?, name: String, cpu: Double, ageS: Int, start: Int64,
                revit: Bool = false) {
        self.pid = pid; self.kind = kind; self.reason = reason; self.bottle = bottle; self.name = name; self.cpu = cpu
        self.ageS = ageS; self.start = start; self.revit = revit
    }

    /// <pid>:<start>, as cleanup --targets takes it.
    public var target: String { "\(pid):\(start)" }

    /// winedevice.exe · probe-drag (deleted) · 98% CPU · 8 h 37 min
    public var line: String {
        var w = [name]
        if let b = bottle { w.append(reason == "bottle_gone" ? String(localized: "\(b) (deleted)") : b) }
        w.append(String(localized: "\(Int(cpu.rounded()))% CPU"))
        w.append(Self.age(ageS))
        return w.joined(separator: " · ")
    }

    static func age(_ s: Int) -> String {
        if s >= 86400 { return String(localized: "\(s / 86400) d \(s % 86400 / 3600) h") }
        if s >= 3600 { return String(localized: "\(s / 3600) h \(s % 3600 / 60) min") }
        return String(localized: "\(s / 60) min")
    }
}

public struct SkippedBottle: Decodable, Equatable, Sendable {
    public let bottle: String
    public let why: String                  // revit_running: Revit is among what Wine left there
    public init(bottle: String, why: String) { self.bottle = bottle; self.why = why }
}
