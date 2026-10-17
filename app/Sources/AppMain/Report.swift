// "Copy diagnostic report": the engine makes it (revit report --json, personal data removed); the app copies the text
// and shows the zip in Finder.
import AppCore
import AppKit

@MainActor enum Report {
    static func copy(app: AppModel, year: Int?, bottle: String?, logDir: String?) async {
        guard let out = await app.query(ReportAction.make(year: year, bottle: bottle, logDir: logDir)) else {
            Confirm.tell(String(localized: "The engine could not be started."), app.engineError ?? ""); return
        }
        guard let r = ReportAction.result(out) else {
            Confirm.tell(String(localized: "No report."), out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)); return
        }
        if let why = r.refused { Confirm.tell(String(localized: "No report."), why); return }
        if let txt = r.reportTxt, let text = try? String(contentsOfFile: txt, encoding: .utf8) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
        if let zip = r.reportZip { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: zip)]) }
        Confirm.tell(String(localized: "Report copied."), String(localized: "Paste it into a GitHub issue and attach report.zip."))
    }
}
