// The sign-in hint: once per install of a bottle (its run record's time), before the first Open from the app's window
// or menu. The words come from the year's SIGNIN (README, docs/troubleshooting.md "Sign-in").
import Foundation

/// An Open the hint stands in front of: the same request afterwards, the Viewer too.
public struct OpenRequest: Hashable, Sendable {
    public let year: Int
    public let bottle: String
    public let viewer: Bool
    public init(year: Int, bottle: String, viewer: Bool = false) { self.year = year; self.bottle = bottle; self.viewer = viewer }
}

public struct SignInHint {
    let defaults: UserDefaults
    static let seenKey = "signInHintSeen", offKey = "signInHintOff"
    public init(defaults: UserDefaults) { self.defaults = defaults }

    static func key(_ bottle: String, _ builtTime: String) -> String { "\(bottle)|\(builtTime)" }

    /// Before this Open: not turned off, this install not seen, and a run record says when it was built.
    public func due(bottle: String, builtTime: String?) -> Bool {
        guard let t = builtTime, !t.isEmpty, !defaults.bool(forKey: Self.offKey) else { return false }
        return !(defaults.stringArray(forKey: Self.seenKey) ?? []).contains(Self.key(bottle, t))
    }

    public func mark(bottle: String, builtTime: String?) {
        guard let t = builtTime, !t.isEmpty else { return }
        var seen = defaults.stringArray(forKey: Self.seenKey) ?? []
        let k = Self.key(bottle, t)
        if !seen.contains(k) { seen.append(k); defaults.set(seen, forKey: Self.seenKey) }
    }

    public func turnOff() { defaults.set(true, forKey: Self.offKey) }
}

public struct SignInText: Equatable, Sendable {
    public let browser: Bool
    public let steps: [String]
    public let note: String?

    /// idmgrBottles: every bottle on this Mac that signs in through the browser, of any year.
    public static func make(bottle: String, signin: String, idmgrBottles: [String]) -> SignInText {
        guard signin == "idmgr" else {
            return SignInText(browser: false, steps: [
                String(localized: "Sign in in Revit's own window."),
                String(localized: "If Revit then hangs on the splash screen, quit it and start it again."),
            ], note: nil)
        }
        let note = Set(idmgrBottles).subtracting([bottle]).isEmpty ? nil : String(localized: """
            Each of them has its own Autodesk Sign-In app. Only the one of this bottle signs you in. If the browser does not \
            ask and Revit keeps waiting, it remembered another one: in Firefox, Settings → General → Applications, set \
            adskidmgr to Always ask.
            """)
        return SignInText(browser: true, steps: [
            String(localized: "Revit opens the Autodesk sign-in page in your browser."),
            String(localized: "Sign in with your Autodesk account, as usual."),
            String(localized: "The browser asks which app opens the link. Choose Autodesk Sign-In (\(bottle))."),
        ], note: note)
    }
}
