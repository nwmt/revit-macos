// The notification at the end of a run (the app posts it with UserNotifications; the tests record it).
import Foundation

@MainActor public protocol Notifier {
    func post(title: String, body: String, url: URL?)
}
