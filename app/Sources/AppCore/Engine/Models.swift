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
    public var yearNumber: Int? { Int(year) }

    public init(name: String, year: String, revit: Bool, running: Bool, revitPids: [Int32] = [], addins: [String]) {
        self.name = name; self.year = year; self.revit = revit; self.running = running; self.revitPids = revitPids
        self.addins = addins
    }

    enum CodingKeys: String, CodingKey { case name, year, revit, running, revitPids, addins }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name), year: try c.decode(String.self, forKey: .year),
                  revit: try c.decode(Bool.self, forKey: .revit), running: try c.decode(Bool.self, forKey: .running),
                  revitPids: try c.decodeIfPresent([Int32].self, forKey: .revitPids) ?? [],
                  addins: try c.decode([String].self, forKey: .addins))
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
    public let notes: [String]
}

public struct PlanItem: Decodable, Equatable, Sendable {
    public let label: String
    public let bytes: Int64?                // nil: not measured (apps)
}
