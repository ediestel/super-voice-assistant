import Foundation
import UserNotifications

/// A banner notification, posted with `AppNotificationCenter.default.deliver(_:)`.
/// Same shape as the deprecated NSUserNotification it replaces; built on UserNotifications.
final class AppNotification {
    /// Set `soundName` to this to play the default notification sound.
    static let defaultSoundName = "default"

    var title: String?
    var subtitle: String?
    var informativeText: String?
    var soundName: String?
}

/// Delivers `AppNotification`s through UNUserNotificationCenter. Asks for permission once
/// (on first use; `applicationDidFinishLaunching` touches it so the prompt comes at launch).
final class AppNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    static let `default` = AppNotificationCenter()

    private override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                print("⚠️ Notifications: authorization failed: \(error.localizedDescription)")
            } else if !granted {
                print("⚠️ Notifications: not allowed — enable them in System Settings → Notifications")
            }
        }
    }

    func deliver(_ notification: AppNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title ?? ""
        content.subtitle = notification.subtitle ?? ""
        content.body = notification.informativeText ?? ""
        if notification.soundName != nil { content.sound = .default }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("⚠️ Notifications: \(error.localizedDescription)") }
        }
    }

    /// Show banners even while the app is frontmost (e.g. its Settings window has focus).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
