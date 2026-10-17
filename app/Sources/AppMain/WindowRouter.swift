// Window requests from places that cannot open a window themselves (a notification click, the launch, a menu item
// after an alert): the menu bar label observes them and opens the window.
import AppCore
import Observation
import SwiftUI

enum Route: Equatable {
    case run, wizard, settings
    case addins(BottleRef)

    var id: String {
        switch self { case .run: "run"; case .wizard: "wizard"; case .settings: "settings"; case .addins: "addins" }
    }
}

@MainActor @Observable final class WindowRouter {
    var pending: Route?
    func open(_ r: Route) { pending = r }
}

extension View {
    /// A window of the app: counted, so the app shows in the Dock and in Cmd-Tab while any is open.
    func appWindow(_ env: AppEnvironment) -> some View {
        onAppear { env.windowAppeared() }.onDisappear { env.windowGone() }
    }
}
