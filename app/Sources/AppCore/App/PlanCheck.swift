// What a person confirmed is what runs: a sheet keeps the plan it showed and compares it with a new one read at the
// button. Sizes change by themselves and do not count; everything that says what happens does.
import Foundation

extension RemovePlan {
    public var fingerprint: [String] {
        [command, bottle, String(nothing ?? false), String(addinsReset ?? false), String(restorePoint ?? true)]
            + delete.map(\.label) + ["|"] + (kept ?? []) + ["|"] + notes
            + ["|", from ?? "", buildNew ?? "", blocked ?? ""]
    }
}

extension RollbackPlan {
    public var fingerprint: [String] { [command, bottle, id, time, String(bottleExists)] }
}

extension PointsPlan {
    public var fingerprint: [String] { [command, bottle, String(unfinished)] + ids }
}

/// The confirmation of a sheet: Go is on for a typed year, when the sheet asks for one.
public struct SheetGate: Equatable, Sendable {
    public let year: Int?
    public var typed = ""
    public init(year: Int?) { self.year = year }
    public var open: Bool { year.map { typed.trimmingCharacters(in: .whitespaces) == String($0) } ?? true }
    public mutating func reset() { typed = "" }
}
