// A Revit file opened from Finder (spec 2026-10-31-finder-open): the engine decides where it goes (`open <file> --dry-run
// --json`), this model walks the files one at a time and asks only what the engine leaves to the user. It never passes
// a file to a Revit of another year: that decision is not here. A copy for a newer Revit is made on an explicit choice.
import Foundation

/// The engine's answer. action: open | pick_bottle | choose | unreadable.
public struct OpenPlan: Decodable, Equatable, Sendable {
    public struct Place: Decodable, Equatable, Sendable { public let name: String }
    public struct Newer: Decodable, Equatable, Sendable { public let year: Int; public let bottle: String }
    public let action: String
    public let format: Int?
    public let worksharing: String
    public let bottles: [Place]
    public let newer: [Newer]
    public let canAdd: Bool
    public let say: String
    public var shared: Bool { !worksharing.isEmpty && worksharing != "Not enabled" }
}

public enum FileChoice: Equatable, Sendable { case cancel, add, copy }

/// The dialogs (AppMain draws them; the tests answer them).
@MainActor public protocol FileOpenAsking {
    func tell(file: String, _ text: String)
    /// nil: cancelled.
    func pickBottle(file: String, year: Int, bottles: [String]) -> String?
    func choose(file: String, format: Int, canAdd: Bool, copyTo: Int?, shared: Bool) -> FileChoice
    func addRevit()
}

@MainActor public final class FileOpenModel {
    private let engine: any EngineClient
    private let ask: any FileOpenAsking
    private var queue: [URL] = []
    private var ready = false
    private var running = false

    public init(engine: any EngineClient, ask: any FileOpenAsking) { self.engine = engine; self.ask = ask }

    /// The files Finder gave. They wait for start(): they may arrive before the app has finished launching.
    public func add(_ urls: [URL]) async {
        queue += urls
        await drain()
    }

    /// The app is up: the first files go now.
    public func start() async {
        ready = true
        await drain()
    }

    private func drain() async {
        guard ready, !running else { return }
        running = true
        defer { running = false }
        while !queue.isEmpty { await open(queue.removeFirst()) }
    }

    private func open(_ url: URL) async {
        let file = url.lastPathComponent
        guard let out = await query(["open", url.path, "--dry-run", "--json"]) else {
            ask.tell(file: file, String(localized: "The engine could not be started.")); return
        }
        guard out.exitCode == 0, let plan = try? JSONDecoder.engine.decode(OpenPlan.self, from: out.stdout) else {
            ask.tell(file: file, out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)); return
        }
        switch plan.action {
        case "open":
            await send(url, ["--bottle", plan.bottles[0].name])
        case "pick_bottle":
            guard let y = plan.format, let b = ask.pickBottle(file: file, year: y, bottles: plan.bottles.map(\.name)) else { return }
            await send(url, ["--bottle", b])
        case "choose":
            guard let y = plan.format else { return }
            let next = plan.shared ? nil : plan.newer.first
            switch ask.choose(file: file, format: y, canAdd: plan.canAdd, copyTo: next?.year, shared: plan.shared) {
            case .cancel: break
            case .add: ask.addRevit()
            case .copy: if let next { await send(url, ["--copy-for", String(next.year), "--bottle", next.bottle]) }
            }
        default:
            ask.tell(file: file, plan.say)
        }
    }

    private func send(_ url: URL, _ args: [String]) async {
        guard let out = await query(["open", url.path] + args) else {
            ask.tell(file: url.lastPathComponent, String(localized: "The engine could not be started.")); return
        }
        if out.exitCode != 0 { ask.tell(file: url.lastPathComponent, out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func query(_ args: [String]) async -> EngineOutput? { try? await engine.run(args) }
}
