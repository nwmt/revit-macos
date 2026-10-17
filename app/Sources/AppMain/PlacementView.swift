// The app runs from outside the Applications folders (a DMG, Downloads): it asks to be moved there (spec §3).
import AppKit

@MainActor enum Placement {
    static func ask(name: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = String(localized: "Move \(name) to the Applications folder, then open it again.")
        a.addButton(withTitle: String(localized: "Quit"))
        a.addButton(withTitle: String(localized: "Not now"))
        if a.runModal() == .alertFirstButtonReturn { NSApplication.shared.terminate(nil) }
    }
}
