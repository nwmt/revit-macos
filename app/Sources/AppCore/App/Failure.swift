// What went wrong in a run, as the screen the app shows (spec §4). The words are the engine's: the text is its last
// error message (a failed step's or action's log tail), else the last lines it printed.
import Foundation

public enum Failure: Equatable, Sendable {
    case busy(owner: String)
    case sourceMismatch(text: String)          // the UI offers both SourceChoice buttons when retryRequest is set
    case inUse(text: String)
    case noSpace(logDir: String)
    case downloadBroken(logDir: String)        // Retry = retryRequest (the engine resumes the .part)
    case crossoverMissing, rosettaMissing
    case partial(steps: [String], logDir: String, downloadFailed: Bool)   // downloadFailed: reason "download" → Retry too
    case failed(at: String, text: String, logDir: String)   // at: failed_action, else the last failed step, else ""
    case interrupted(logDir: String)
    case usage(text: String)

    public static func from(end: EndInfo, messages: [Message], console: String, status: EngineStatus?) -> Failure? {
        let text = messages.last { $0.level == "error" }?.text ?? lastLines(console, 3)
        switch end.kind {
        case .ok, .stopped: return nil
        case .busy: return .busy(owner: status?.busy.command ?? "")
        case .sourceMismatch: return .sourceMismatch(text: text)
        case .inUse: return .inUse(text: text)
        case .partial: return .partial(steps: end.failedSteps, logDir: end.logDir, downloadFailed: end.reason == "download")
        default: break
        }
        if end.reason == "no_space" { return .noSpace(logDir: end.logDir) }
        if end.reason == "download" { return .downloadBroken(logDir: end.logDir) }
        if status?.crossover.found == false { return .crossoverMissing }
        if status?.rosetta == false { return .rosettaMissing }
        if end.kind == .usage { return .usage(text: text) }
        return .failed(at: end.failedAction.isEmpty ? (end.failedSteps.last ?? "") : end.failedAction, text: text, logDir: end.logDir)
    }

    /// The last n non-empty lines of a text.
    static func lastLines(_ s: String, _ n: Int) -> String {
        s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(n).joined(separator: "\n")
    }
}
