// One sheet over the main window at a time. A request while a sheet is shown, is closing (between its binding going nil
// and its onDismiss) or while a page shows a sheet of its own waits, and the last one waiting wins. A sheet closed to
// lead somewhere (close(then:)) runs that first: its next step goes before whatever waited. The owner runs the steps it
// is handed (a step may show a sheet: it must not run inside a mutation of this value), then calls showQueued().
import Foundation

public struct SheetQueue<Sheet: Equatable> {
    public private(set) var shown: Sheet?
    public private(set) var queued: Sheet?
    private(set) var closing = false
    private(set) var localSheets = 0
    private var then: (() -> Void)?

    public init() {}

    public var busy: Bool { shown != nil || closing || localSheets > 0 }

    /// The sheet already up (or already waiting) is not asked for twice.
    public mutating func show(_ s: Sheet) {
        guard s != shown, s != queued else { return }
        if busy { queued = s } else { shown = s }
    }

    /// Closes the shown sheet; `then` is handed back by gone(), before anything queued. No sheet: it is handed back now.
    public mutating func close(then t: (() -> Void)? = nil) -> (() -> Void)? {
        guard shown != nil else { return t }
        then = t; dropped(); return nil
    }

    /// The sheet's binding went nil (Esc, its own dismiss, close): busy until gone().
    public mutating func dropped() {
        guard shown != nil else { return }
        closing = true; shown = nil
    }

    /// onDismiss: the sheet is off the window. Hands back its next step; the owner runs it, then showQueued().
    public mutating func gone() -> (() -> Void)? {
        closing = false
        let t = then; then = nil
        return t
    }

    /// A page's own sheet (New connection, an add-in's license) came or went.
    public mutating func localShown() { localSheets += 1 }
    public mutating func localGone() { localSheets = max(0, localSheets - 1); showQueued() }

    public mutating func showQueued() {
        guard !busy, let q = queued else { return }
        queued = nil; shown = q
    }
}
