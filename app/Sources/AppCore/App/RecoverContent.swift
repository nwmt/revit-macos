// The ladder for a Revit in trouble: each step goes further than the one before. Pure: the sheet draws it and says why a
// step is off.
import Foundation

public enum RecoverAction: Equatable, Sendable { case show, forceQuit, closeAll, check, rollBack(String), report, rebuild }

public struct RecoverStep: Equatable, Sendable {
    public let title, text, risk, button: String
    public let action: RecoverAction
    public let off: String?                 // why it cannot run now
    public let danger: Bool
}

public enum RecoverContent {
    /// newest: the id of the newest restore point of this bottle.
    public static func steps(year: Int, running: Bool, busy: Bool, newest: String?) -> [RecoverStep] {
        let y = String(year)
        let working = String(localized: "A task is running.")
        let quit = String(localized: "Force quit Revit first.")
        return [
            RecoverStep(title: String(localized: "Look for a waiting dialog"),
                        text: String(localized: "A Revit dialog may be waiting for you behind the window. Large models also draw slowly the first time."),
                        risk: String(localized: "No risk"), button: String(localized: "Show Revit"), action: .show,
                        off: running ? nil : String(localized: "Revit is not running."), danger: false),
            RecoverStep(title: String(localized: "Force quit Revit \(y)"),
                        text: String(localized: "Unsaved work is lost; backup copies (.0001.rvt) stay."),
                        risk: String(localized: "Unsaved work"), button: String(localized: "Force quit…"), action: .forceQuit,
                        off: !running ? String(localized: "Revit is not running.") : busy ? working : nil, danger: false),
            RecoverStep(title: String(localized: "Close all of Wine"),
                        text: String(localized: "When Force quit does not help: ends every Windows program on this Mac, Revit too."),
                        risk: String(localized: "Unsaved work"), button: String(localized: "Close all…"), action: .closeAll,
                        off: busy ? working : nil, danger: false),
            RecoverStep(title: String(localized: "Check health"),
                        text: String(localized: "Checks Revit, its bottle and this Mac, and says what to do. Changes nothing."),
                        risk: String(localized: "No risk"), button: String(localized: "Check"), action: .check, off: nil, danger: false),
            RecoverStep(title: String(localized: "Roll back"),
                        text: String(localized: "Worse since the last update or rebuild? Brings back the bottle from before it."),
                        risk: String(localized: "Newer changes"), button: String(localized: "Roll back…"), action: .rollBack(newest ?? ""),
                        off: newest == nil ? String(localized: "No restore point.") : running ? quit : busy ? working : nil, danger: false),
            RecoverStep(title: String(localized: "Report the problem"),
                        text: String(localized: "A report for a GitHub issue, with personal data removed. Nothing is sent on its own."),
                        risk: String(localized: "No risk"), button: String(localized: "Make report"), action: .report, off: nil, danger: false),
            RecoverStep(title: String(localized: "Rebuild Revit \(y)"),
                        text: String(localized: "A fresh bottle with the newest fixes, after a restore point when one can be kept. Settings and add-ins reset."),
                        risk: String(localized: "Resets settings"), button: String(localized: "Rebuild…"), action: .rebuild,
                        off: running ? quit : busy ? working : nil, danger: true),
        ]
    }
}

/// Which Revit's recent files the Library shows first: the one running, else the first.
public enum RecentChoice {
    public static func bottle(_ cards: [VersionCard], picked: String?) -> VersionCard? {
        cards.first { $0.bottle == picked } ?? cards.first(where: \.running) ?? cards.first
    }
}
