// A token on the clipboard: for this Mac only (no Universal Clipboard), marked so that clipboard managers leave it out
// (nspasteboard.org), and gone after a minute, on "I saved it" and when the app quits, unless something else was copied.
import AppKit

@MainActor public final class TokenClipboard {
    public static let shared = TokenClipboard(.general)
    public static let marks = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"].map { NSPasteboard.PasteboardType($0) }

    private let board: NSPasteboard
    private var mine: Int?

    public init(_ board: NSPasteboard) { self.board = board }

    public func copy(_ s: String, keepFor seconds: Double = 60) {
        board.prepareForNewContents(with: .currentHostOnly)
        board.setString(s, forType: .string)
        for m in Self.marks { board.setData(Data(), forType: m) }
        let n = board.changeCount
        mine = n
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if self?.mine == n { self?.clear() }
        }
    }

    public func clear() {
        if mine == board.changeCount { board.clearContents() }
        mine = nil
    }
}
