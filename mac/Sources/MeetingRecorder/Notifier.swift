import UserNotifications

/// A macOS banner as well as the notch, for when the call was full screen or on another display.
/// Its buttons do the same as the notch's.
@MainActor
enum Notifier {
    static var onStop: (() -> Void)?
    static var onKeep: (() -> Void)?

    private static let category = "meeting-over"
    private static let delegate = Delegate()

    static func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([UNNotificationCategory(
            identifier: category,
            actions: [
                UNNotificationAction(identifier: "stop", title: "Stop & Save"),
                UNNotificationAction(identifier: "keep", title: "Keep recording"),
            ],
            intentIdentifiers: []
        )])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func meetingOver(reason: String, seconds: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting over?"
        content.body = "\(reason) Recording stops and saves in \(seconds) seconds."
        content.categoryIdentifier = category
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: category, content: content, trigger: nil))
    }

    static func limitSoon(minutes: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Recording stops in 2 minutes"
        content.body = "It reaches the \(minutes)-minute limit set in Settings → Recording, then saves."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "limit", content: content, trigger: nil))
    }

    static func micSilent() {
        let content = UNMutableNotificationContent()
        content.title = "Your mic hears nothing"
        content.body = "The recording is running but the microphone is silent. Check that it isn't muted or unplugged."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "mic-silent", content: content, trigger: nil))
    }

    /// Banner too, for when the call is full screen or on another display.
    static func mention(_ line: String) {
        let content = UNMutableNotificationContent()
        content.title = "Someone said your name"
        content.body = line
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "mention", content: content, trigger: nil))
    }

    static func clear() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [category])
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        // Show the banner even though the app counts as active.
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            let action = response.actionIdentifier
            Task { @MainActor in
                if action == "keep" { Notifier.onKeep?() } else if action == "stop" { Notifier.onStop?() }
                completionHandler()
            }
        }
    }
}
