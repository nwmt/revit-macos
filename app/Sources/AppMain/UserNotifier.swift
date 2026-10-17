// The notifications (the end of a run, a new version), through UserNotifications; permission is asked at the first one.
// Clicking a run's opens the progress window, a new version's its release page.
import AppCore
import AppKit
import UserNotifications

@MainActor final class UserNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate {
    let router: WindowRouter
    private var asked = false

    init(router: WindowRouter) {
        self.router = router
        super.init()
        if Self.bundled { UNUserNotificationCenter.current().delegate = self }
    }

    /// UserNotifications needs a real bundle: a bare binary (swift run) has none.
    static var bundled: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    func post(title: String, body: String, url: URL?) {
        guard Self.bundled else { return }
        let c = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        content.userInfo = NotificationLink.userInfo(url, release: url.map { $0.scheme == "https" } ?? false)
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let first = !asked; asked = true
        Task {
            if first { _ = try? await c.requestAuthorization(options: [.alert, .sound]) }
            try? await c.add(req)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let release = NotificationLink.isRelease(info) ? NotificationLink.url(from: info) : nil
        await MainActor.run {
            if let release { NSWorkspace.shared.open(release) } else { router.open(.run) }   // a new version: its page; a run: progress
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
