import UIKit
import Capacitor

/// The app's one window scene. iOS 27 won't launch an app built with its SDK unless it adopts the scene life
/// cycle. The window and MainViewController come from Main.storyboard (UISceneStoryboardFile in Info.plist).
/// URL opens and Universal Links now reach the scene, not the app delegate, so they're forwarded to Capacitor's
/// App API from here.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // What launched the app, if anything.
        connectionOptions.urlContexts.forEach(open)
        connectionOptions.userActivities.forEach(continueActivity)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        URLContexts.forEach(open)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        continueActivity(userActivity)
    }

    private func open(_ context: UIOpenURLContext) {
        var options: [UIApplication.OpenURLOptionsKey: Any] = [:]
        if let source = context.options.sourceApplication { options[.sourceApplication] = source }
        _ = ApplicationDelegateProxy.shared.application(UIApplication.shared, open: context.url, options: options)
    }

    private func continueActivity(_ activity: NSUserActivity) {
        _ = ApplicationDelegateProxy.shared.application(UIApplication.shared, continue: activity) { _ in }
    }
}
