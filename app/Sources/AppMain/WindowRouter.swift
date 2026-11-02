// Window requests from places that cannot open a window themselves (a notification click, the launch, a menu item
// after an alert): the menu bar label observes them and opens the window. The main window's place and sheets live here
// too, so a menu item or a failure can lead to them: one sheet at a time (SheetQueue), the pages' own sheets counted.
import AppCore
import Observation
import SwiftUI

enum Route: Equatable {
    case main, run, settings
    case addins(BottleRef)

    var id: String {
        switch self { case .main, .run, .addins: "main"; case .settings: "settings" }
    }
}

/// Where the main window is.
enum Place: Hashable { case library, activity, bottle(BottleRef) }

/// A decision over the main window. plan: remove or rebuild. points: clear is old or all.
enum SheetRequest: Identifiable, Equatable {
    case plan(RunRequest)
    case rollback(year: Int, bottle: String, id: String)
    case points(year: Int, bottle: String, clear: String)

    var id: String {
        switch self {
        case .plan(let r): "plan\(r.arguments)"
        case .rollback(let y, let b, let i): "rollback\(y)\(b)\(i)"
        case .points(let y, let b, let c): "points\(y)\(b)\(c)"
        }
    }

    /// The sheet of a run that needs one: Retry comes here.
    static func of(_ r: RunRequest, bottleExists: Bool) -> SheetRequest? {
        switch r {
        case .remove, .rebuild, .update: .plan(r)
        case let .rollback(y, b, id): .rollback(year: y, bottle: b, id: id)
        case let .clearPoints(y, b, _, _): .points(year: y, bottle: b, clear: bottleExists ? "old" : "all")   // a new plan, shown again
        default: nil
        }
    }
}

/// A sheet over the main window.
enum MainSheet: Identifiable, Equatable {
    case plan(SheetRequest)
    case recover(BottleRef)
    case addVersion
    case signIn(OpenRequest)

    var id: String {
        switch self {
        case .plan(let s): s.id
        case .recover(let r): "recover\(r.id)"
        case .addVersion: "addVersion"
        case .signIn(let o): "signIn\(o.year)\(o.bottle)\(o.viewer)"
        }
    }
}

@MainActor @Observable final class WindowRouter {
    var pending: Route?
    var place: Place = .library
    var tab: VersionTab = .overview
    private(set) var sheets = SheetQueue<MainSheet>()
    var healthWanted = false                // Maintenance runs the check when it next shows

    var sheet: MainSheet? { sheets.shown }

    func open(_ r: Route) {
        switch r {
        case .run: place = .activity
        case .addins(let ref): place = .bottle(ref); tab = .addins
        default: break
        }
        pending = r
    }

    func page(_ ref: BottleRef, tab t: VersionTab = .overview) {
        place = .bottle(ref); tab = t; pending = .main
    }

    /// A sheet over the main window; it waits while another is up.
    func show(_ s: MainSheet) { sheets.show(s); pending = .main }
    func ask(_ s: SheetRequest) { show(.plan(s)) }
    func recover(_ ref: BottleRef) { show(.recover(ref)) }
    func addVersion() { show(.addVersion) }

    /// Closes the sheet; `then` runs once it is off the window, before any sheet that waited.
    func close(then t: (() -> Void)? = nil) { if let now = sheets.close(then: t) { now() } }

    /// From the ladder to another sheet: one sheet leaves before the next comes.
    func leaveRecover(then s: SheetRequest) { close { self.ask(s) } }

    /// The sheet binding went nil, however the sheet was closed.
    func dropped() { sheets.dropped() }
    /// onDismiss: the sheet's next step, then what waited.
    func gone() { let t = sheets.gone(); t?(); sheets.showQueued() }

    func localShown() { sheets.localShown() }
    func localGone() { sheets.localGone() }
}

extension View {
    /// A sheet of a page in the main window: the router counts it, so its own sheets wait for it.
    func routedSheet<C: View>(isPresented: Binding<Bool>, router: WindowRouter, onDismiss: (() -> Void)? = nil,
                              @ViewBuilder content: @escaping () -> C) -> some View {
        sheet(isPresented: isPresented, onDismiss: { onDismiss?(); router.localGone() }) {
            content().onAppear { router.localShown() }
        }
    }

    /// A window of the app: counted, so a menu bar only app shows in the Dock and in Cmd-Tab while any is open.
    func appWindow(_ env: AppEnvironment) -> some View {
        onAppear { env.windowAppeared() }.onDisappear { env.windowGone() }
    }
}
