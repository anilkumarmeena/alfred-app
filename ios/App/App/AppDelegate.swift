import UIKit
import Capacitor
import AlfredAudioPlugin

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    // The window, URL opens and Universal Links belong to SceneDelegate.

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Before launch finishes, so a notification tap that opened the app reaches the page.
        PushNotifications.shared.install()
        SessionActivity.shared.install()
        return true
    }

    // Forwarded the way Capacitor plugins expect; PushNotifications hands the token to alfred.web.
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Swiped away in the app switcher: iOS would leave the Live Activity up.
        SessionActivity.endBeforeQuit()
    }
}
