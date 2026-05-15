import Foundation
import UserNotifications
import AppKit

/// Wraps UNUserNotificationCenter. Click actions open the URL passed in userInfo
/// via NSWorkspace.shared.open — which routes to the user's default browser.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    enum AuthState { case unknown, authorized, denied }

    private(set) var authState: AuthState = .unknown

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authState = granted ? .authorized : .denied
        }
    }

    func refreshAuthState(_ completion: ((AuthState) -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let state: AuthState
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: state = .authorized
            case .denied: state = .denied
            case .notDetermined: state = .unknown
            @unknown default: state = .unknown
            }
            DispatchQueue.main.async {
                self?.authState = state
                completion?(state)
            }
        }
    }

    /// Posts a banner; clicking it opens `url` in the default browser.
    func post(title: String, subtitle: String, url: String, dedupeKey: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.userInfo = ["url": url]
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: dedupeKey,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show the banner even when the app is frontmost.
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
