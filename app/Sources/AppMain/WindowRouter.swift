// Window requests from places that cannot open a window themselves (a notification click, the launch, a menu item
// after an alert): the menu bar label observes them and opens the window. The main window's place and sheet live here
// too, so a menu item or a failure can lead to them.
import AppCore
import Observation
import SwiftUI

enum Route: Equatable {
    case main, run, wizard, settings
    case addins(BottleRef)

    var id: String {
        switch self { case .main, .run, .addins: "main"; case .wizard: "wizard"; case .settings: "settings" }
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
    static func of(_ r: RunRequest) -> SheetRequest? {
        switch r {
        case .remove, .rebuild: .plan(r)
        case let .rollback(y, b, id): .rollback(year: y, bottle: b, id: id)
        case let .clearPoints(y, b, _, _): .points(year: y, bottle: b, clear: "old")
        default: nil
        }
    }
}

@MainActor @Observable final class WindowRouter {
    var pending: Route?
    var place: Place = .library
    var tab: VersionTab = .overview
    var sheet: SheetRequest?

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

    func ask(_ s: SheetRequest) { sheet = s; pending = .main }
}

extension View {
    /// A window of the app: counted, so a menu bar only app shows in the Dock and in Cmd-Tab while any is open.
    func appWindow(_ env: AppEnvironment) -> some View {
        onAppear { env.windowAppeared() }.onDisappear { env.windowGone() }
    }
}
