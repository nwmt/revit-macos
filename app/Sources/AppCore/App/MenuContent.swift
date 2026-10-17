// What the menu bar menu shows (spec §3): the Revit bottles, one line saying what the engine is doing or what went
// wrong, and whether the items that change something are on. Pure: the views draw it, the tests check it.
import Foundation

public struct MenuContent: Equatable {
    public let bottles: [BottleItem]
    public let activity: Activity?
    public let changesEnabled: Bool

    /// busy = AppModel.isBusy (it also knows a start under way).
    public static func make(status: EngineStatus?, watched: WatchedRun?, failure: Failure?, busy: Bool) -> MenuContent {
        let bottles = (status?.bottles ?? []).compactMap { b in
            b.yearNumber.map { BottleItem(title: "Revit \($0) · \(b.name)", year: $0, bottle: b.name, running: b.running) }
        }
        return MenuContent(bottles: bottles, activity: activity(status: status, watched: watched, failure: failure), changesEnabled: !busy)
    }

    static func activity(status: EngineStatus?, watched w: WatchedRun?, failure: Failure?) -> Activity? {
        if let w, w.phase == .running || w.phase == .finishing {
            let verb = verb(command(w), year(w))
            if w.phase == .finishing { return Activity(title: String(localized: "\(verb) — finishing…"), cancellable: false, isFailure: false) }
            let suffix = doing(w.state)
            let title = suffix.map { "\(verb) — \($0)" } ?? verb
            let cancellable = w.record.map { $0.request.cancellable } ?? false
            return Activity(title: title, cancellable: cancellable, isFailure: false)
        }
        if let b = status?.busy, b.busy {
            return Activity(title: String(localized: "Busy: \(b.command)"), cancellable: false, isFailure: false)
        }
        if let w, let failure {
            let what = "Revit \(year(w)): \(command(w))"
            let title: String
            switch failure {
            case .partial: title = String(localized: "\(what) finished with problems — details")
            case .interrupted: title = String(localized: "\(what) was interrupted — details")
            default: title = String(localized: "\(what) failed — details")
            }
            return Activity(title: title, cancellable: false, isFailure: true)
        }
        return nil
    }

    static func command(_ w: WatchedRun) -> String {
        w.state.command ?? w.record.map { $0.request.arguments[0] } ?? ""
    }

    static func year(_ w: WatchedRun) -> String {
        (w.state.year ?? w.record?.request.year).map(String.init) ?? ""
    }

    public static func verb(_ command: String, _ y: String) -> String {
        switch command {
        case "install": String(localized: "Installing Revit \(y)")
        case "rebuild": String(localized: "Rebuilding Revit \(y)")
        case "addins": String(localized: "Adding add-ins to Revit \(y)")
        case "remove": String(localized: "Removing Revit \(y)")
        case "stop": String(localized: "Stopping Revit \(y)")
        case "check": String(localized: "Checking Revit \(y)")
        default: "\(command) \(y)"
        }
    }

    /// The current action in words; the download's percent while Revit downloads.
    public static func doing(_ s: RunState) -> String? {
        guard let a = s.currentAction else { return nil }
        if a == "revit", let p = s.downloadPercent { return String(localized: "Downloading \(p)%") }
        switch a {
        case "shims": return String(localized: "Preparing")
        case "revit": return String(localized: "Downloading Revit")
        case "redist": return String(localized: "Downloading runtimes")
        case "unpack": return String(localized: "Unpacking")
        case "bottle": return String(localized: "Creating the bottle")
        case "steps": return s.currentStep.map { String(localized: "Installing (\($0))") } ?? String(localized: "Installing")
        case "apps": return String(localized: "Making the apps")
        default: return a
        }
    }
}

public struct BottleItem: Equatable, Sendable {
    public let title: String
    public let year: Int
    public let bottle: String
    public let running: Bool
}

public struct Activity: Equatable, Sendable {
    public let title: String
    public let cancellable: Bool
    public let isFailure: Bool
}

/// A bottle, as the add-ins window's value.
public struct BottleRef: Hashable, Codable, Sendable {
    public let year: Int
    public let bottle: String
    public init(year: Int, bottle: String) { self.year = year; self.bottle = bottle }
}
