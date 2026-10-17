// What one engine run has done so far, built from its events: the actions and steps in the order they first came,
// the last download progress, the messages and the end. Nothing changes once the end is there.
import Foundation

public struct RunState: Equatable, Sendable {
    public var runID: String?
    public var command: String?
    public var year: Int?
    public var bottle: String?
    public var pid: Int?
    public var actions: [Item] = []            // first-seen order; a later event for the same id updates it
    public var steps: [Item] = []
    public var download: DownloadProgress?     // the last progress event
    public var messages: [Message] = []
    public var end: EndInfo?

    public init() {}

    /// The last action whose state is "running".
    public var currentAction: String? { actions.last { $0.state == "running" }?.id }
    public var currentStep: String? { steps.last { $0.state == "running" }?.id }

    /// floor(done × 100 / total), at most 100; nil without a total.
    public var downloadPercent: Int? {
        guard let d = download, d.total > 0 else { return nil }
        return Int(min(100, max(0, d.done) * 100 / d.total))
    }

    public mutating func apply(_ e: EngineEvent) {
        guard end == nil else { return }
        switch e {
        case let .start(id, cmd, y, b, p):
            runID = id; command = cmd; year = y; bottle = b; pid = p
        case let .action(id, state, _):
            Self.upsert(&actions, Item(id: id, state: state, detail: nil))
        case let .step(id, state, detail):
            Self.upsert(&steps, Item(id: id, state: state, detail: detail))
        case let .progress(_, done, total):
            download = DownloadProgress(done: done, total: total)
        case let .message(level, text):
            messages.append(Message(level: level, text: text))
        case let .end(info):
            end = info
        case .unknown:
            break
        }
    }

    public static func replay(_ events: [EngineEvent]) -> RunState {
        var s = RunState()
        for e in events { s.apply(e) }
        return s
    }

    private static func upsert(_ items: inout [Item], _ item: Item) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
    }
}

public struct Item: Equatable, Sendable {
    public let id: String
    public var state: String
    public var detail: String?
    public init(id: String, state: String, detail: String?) { self.id = id; self.state = state; self.detail = detail }
}

public struct DownloadProgress: Equatable, Sendable {
    public let done: Int64
    public let total: Int64
    public init(done: Int64, total: Int64) { self.done = done; self.total = total }
}

public struct Message: Equatable, Sendable {
    public let level: String
    public let text: String
    public init(level: String, text: String) { self.level = level; self.text = text }
}
