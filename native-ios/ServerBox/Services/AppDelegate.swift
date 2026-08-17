import Foundation
import UserNotifications
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerForPushNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: AppGroup.pushTokenKey)
        AppGroup.sharedDefaults?.set(token, forKey: AppGroup.pushTokenKey)
        NotificationCenter.default.post(name: .pushTokenDidChange, object: token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        UserDefaults.standard.removeObject(forKey: AppGroup.pushTokenKey)
        NotificationCenter.default.post(name: .pushTokenDidChange, object: nil)
    }

    static func requestPushRegistration() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }
}

extension Notification.Name {
    static let pushTokenDidChange = Notification.Name("native.pushTokenDidChange")
}
