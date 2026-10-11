import Capacitor
import Foundation
import JarvisAudioCore
import UIKit
import UserNotifications

/// APNs notifications, since Web Push doesn't work in an app's web view. The token goes to jarvis.web when a
/// voice session starts (that's when the passcode is known); a tap opens the notification's page on the server.
/// AppDelegate calls `install()` at launch so a tap that launched the app isn't missed.
@MainActor
public final class PushNotifications: NSObject {
    public static let shared = PushNotifications()

    private struct Target: Equatable {
        let server: ServerAddress
        let passcode: String
        let device: String
    }

    /// Set by the plugin once the bridge is up; a tap before that waits in `pending`.
    var open: ((URL) -> Void)? {
        didSet { if let open, let url = pending { pending = nil; open(url) } }
    }
    private var pending: URL?

    private var target: Target?  // the latest session's server and passcode
    private var token: String?
    private var sent: Target?  // the target the current token was last handed to
    private var sending = false
    private var installed = false

    public func install() {
        guard !installed else { return }
        installed = true
        UNUserNotificationCenter.current().delegate = self
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(registered(_:)), name: .capacitorDidRegisterForRemoteNotifications, object: nil)
        nc.addObserver(self, selector: #selector(failed(_:)), name: .capacitorDidFailToRegisterForRemoteNotifications, object: nil)
    }

    func register(server: ServerAddress, passcode: String, device: String) {
        install()
        target = Target(server: server, passcode: passcode, device: device)
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else {
                    return NSLog("JarvisAudio: notifications are turned off for JARVIS in Settings")
                }
            } catch {
                return NSLog("JarvisAudio: notification permission: \(error)")
            }
            // Every time, per Apple: the token can change.
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    @objc private func registered(_ n: Notification) {
        guard let data = n.object as? Data else { return }
        let t = PushRegistration.tokenString(data)
        if t != token { token = t; sent = nil }
        send()
    }

    @objc private func failed(_ n: Notification) {
        // Usually: signed without the Push Notifications capability (aps-environment).
        NSLog("JarvisAudio: APNs registration failed: \(String(describing: n.object))")
    }

    /// Skipped if this target already has the token this launch; failures retry at the next session start.
    private func send() {
        guard !sending, let token, let target, sent != target else { return }
        sending = true
        Task {
            defer {
                sending = false
                if self.target != target { send() }  // a new session started meanwhile
            }
            var req = URLRequest(url: target.server.pushURL, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = PushRegistration.body(
                passcode: target.passcode, device: target.device, token: token,
                environment: Self.environment, topic: Bundle.main.bundleIdentifier ?? "")
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                switch PushRegistration.parse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data) {
                case .success:
                    sent = target
                    NSLog("JarvisAudio: notifications registered with \(target.server.host) (\(Self.environment))")
                case .failure(let r):
                    NSLog("JarvisAudio: notification token not taken: \(r.message)")
                }
            } catch {
                NSLog("JarvisAudio: notification token: \(error.localizedDescription)")
            }
        }
    }

    private static let environment: String = {
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision").flatMap { try? Data(contentsOf: $0) }
        return PushRegistration.environment(provisioningProfile: profile)
    }()

    private func tapped(_ url: String, title: String, body: String) {
        guard let page = ServerSettings.current?.page(url, title: title, body: body) else { return }
        if let open { open(page) } else { pending = page }
    }
}

extension PushNotifications: UNUserNotificationCenterDelegate {
    /// Show in the foreground too: the page may be on another view.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let url = content.userInfo["url"] as? String, title = content.title, body = content.body
        DispatchQueue.main.async {
            if let url { MainActor.assumeIsolated { PushNotifications.shared.tapped(url, title: title, body: body) } }
            completionHandler()
        }
    }
}
