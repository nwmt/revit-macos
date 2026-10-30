// Files from Finder: the application delegate takes them, FileInbox keeps them until the app is up, the alerts here ask
// what FileOpenModel leaves to the user. With no Revit of the file's year, Cancel is the default.
import AppCore
import AppKit

/// Finder's open event can come before AppEnvironment has its model.
@MainActor enum FileInbox {
    static var early: [URL] = []
    static var receive: (([URL]) -> Void)?
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        if let r = FileInbox.receive { r(urls) } else { FileInbox.early += urls }
    }
}

@MainActor final class FileOpenDialogs: FileOpenAsking {
    private let router: WindowRouter

    init(router: WindowRouter) { self.router = router }

    func tell(file: String, _ text: String) { Confirm.tell(file, text) }

    func pickBottle(file: String, year: Int, bottles: [String]) -> String? {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = String(localized: "Open \(file) in which bottle?")
        a.informativeText = String(localized: "Revit \(String(year)) is in several bottles.")
        for b in bottles { a.addButton(withTitle: b) }
        a.addButton(withTitle: String(localized: "Cancel"))
        let i = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return i < bottles.count ? bottles[i] : nil
    }

    func choose(file: String, format: Int, canAdd: Bool, copyTo: Int?, shared: Bool) -> FileChoice {
        NSApp.activate()
        let a = NSAlert()
        let y = String(format)
        a.messageText = String(localized: "\(file) was saved in Revit \(y), which is not on this Mac.")
        var lines: [String] = []
        if let copyTo {
            let t = String(copyTo)
            lines.append(String(localized: "Revit \(t) can open a copy beside the file. The copy becomes a Revit \(t) file for good; your file stays as it is."))
        } else if shared {
            lines.append(String(localized: "This file uses worksharing. To upgrade it, open it in a newer Revit with Detach from Central."))
        }
        if lines.isEmpty && !canAdd { lines.append(String(localized: "No Revit on this Mac can open it.")) }
        a.informativeText = lines.joined(separator: "\n")
        var buttons: [FileChoice] = [.cancel]
        a.addButton(withTitle: String(localized: "Cancel"))
        if canAdd { a.addButton(withTitle: String(localized: "Add Revit \(y)…")); buttons.append(.add) }
        if let copyTo { a.addButton(withTitle: String(localized: "Open a Copy in Revit \(String(copyTo))")); buttons.append(.copy) }
        return buttons[a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue]
    }

    func addRevit() { router.open(.wizard) }
}
