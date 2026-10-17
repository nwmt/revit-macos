// "Copy diagnostic report": revit report --json, for a bottle (and the failed run's log folder) or for the Mac.
import Foundation

public enum ReportAction {
    public static func make(year: Int?, bottle: String?, logDir: String?) -> [String] {
        var a = ["report"]
        if let year, let bottle { a += [String(year), bottle] }
        a.append("--json")
        if let logDir, !logDir.isEmpty { a += ["--run", logDir] }
        return a
    }

    /// The report's answer, whatever the exit code (a refusal is JSON on stdout with exit 1); nil when it is not JSON.
    public static func result(_ out: EngineOutput) -> ReportResult? { try? JSONDecoder.engine.decode(ReportResult.self, from: out.stdout) }
}
