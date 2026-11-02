// The install as the Add Revit sheet draws it: one row per engine action, in the order of the run's plan (or as the
// actions came, from a run that sends none). No overall percent and no time left: the engine knows neither.
import Foundation

public struct Phase: Equatable, Sendable {
    public enum State: Equatable, Sendable { case todo, running, done, failed, skipped }
    public let id: String
    public let title: String
    public let state: State
    public let detail: String
    public let percent: Int?                   // the download's current file only
}

public enum InstallPhases {
    public static func make(_ s: RunState) -> [Phase] {
        var ids = s.plan?.actions ?? []
        for a in s.actions where !ids.contains(a.id) { ids.append(a.id) }
        return ids.map { id in
            let item = s.actions.first { $0.id == id }
            let state = item.map { state($0.state) } ?? .todo
            var detail = "", percent: Int?
            switch (id, state) {
            case ("revit", .running):
                if let p = s.downloadPercent { percent = p; detail = String(localized: "Current file: \(p)%") }
                detail += (detail.isEmpty ? "" : " · ") + String(localized: "resumes if the connection drops")
            case ("steps", .running), ("steps", .failed):
                let total = s.plan?.steps.count ?? s.steps.count
                let ended = s.steps.filter { ["done", "failed", "skipped"].contains($0.state) }.count
                detail = String(localized: "\(ended) of \(total)")
                if let c = s.currentStep { detail += " · \(c)" }
            default: break
            }
            if state == .done { detail = String(localized: "Done") }
            return Phase(id: id, title: title(id), state: state, detail: detail, percent: percent)
        }
    }

    public static func title(_ id: String) -> String {
        switch id {
        case "shims": String(localized: "Prepare")
        case "revit": String(localized: "Download Revit")
        case "redist": String(localized: "Download runtimes")
        case "unpack": String(localized: "Unpack")
        case "bottle": String(localized: "Create the bottle")
        case "steps": String(localized: "Install Revit and fixes")
        case "apps": String(localized: "Make the apps")
        default: id
        }
    }

    static func state(_ s: String) -> Phase.State {
        switch s {
        case "running": .running
        case "done": .done
        case "failed": .failed
        case "skipped": .skipped
        default: .todo
        }
    }
}
