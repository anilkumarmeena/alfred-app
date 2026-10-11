import AVFoundation
import Capacitor
import Foundation
import JarvisAudioCore
import UserNotifications
import WebKit

/// The page's bridge to VoiceSession and the server address setting; names match src/definitions.ts. Also
/// handles jarvis-app://retry and jarvis-app://setup from the bundled error page.
@objc(JarvisAudioPlugin)
public class JarvisAudioPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "JarvisAudioPlugin"
    public let jsName = "JarvisAudio"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setMuted", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "toggleMute", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setSpeaker", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "restoreAfterCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sendText", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getMicMode", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "showMicModes", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getServerUrl", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setServerUrl", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearServerUrl", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "checkPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestPermissions", returnType: CAPPluginReturnPromise),
    ]

    private static let scheme = "jarvis-app"

    override public func load() {
        Task { @MainActor in
            VoiceSession.shared.onEvent = { [weak self] name, data in self?.notifyListeners(name, data: data) }
            PushNotifications.shared.open = { [weak self] url in self?.load(url) }
        }
    }

    // MARK: - Session

    @objc func start(_ call: CAPPluginCall) {
        guard let passcode = call.getString("passcode"), !passcode.isEmpty else {
            return call.reject("Enter your passcode first.", "UNAUTHORIZED")
        }
        let given = call.getString("serverUrl").flatMap { try? ServerAddress($0) }
        guard let server = given ?? ServerSettings.current else {
            return call.reject("JARVIS's address isn't set.", "NO_SERVER")
        }
        let device = call.getString("device").flatMap { $0.isEmpty ? nil : $0 } ?? "iphone"
        let muted = call.getBool("muted") ?? false, speakerOff = call.getBool("speakerOff") ?? false
        Task { @MainActor in
            do {
                call.resolve(try await VoiceSession.shared.start(server: server, passcode: passcode, device: device, muted: muted,
                                                                 speakerOff: speakerOff))
                PushNotifications.shared.register(server: server, passcode: passcode, device: device)
            } catch let f as VoiceSession.Failure {
                call.reject(f.message, f.code)
            } catch {
                call.reject(error.localizedDescription, "SERVER")
            }
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        Task { @MainActor in
            VoiceSession.shared.stop()
            call.resolve()
        }
    }

    @objc func setMuted(_ call: CAPPluginCall) {
        guard let m = call.getBool("muted") else { return call.reject("Say muted: true or false.") }
        reply(call, "muted") { try await VoiceSession.shared.setMuted(m, source: "user") }
    }

    @objc func toggleMute(_ call: CAPPluginCall) {
        reply(call, "muted") { try await VoiceSession.shared.setMuted(!VoiceSession.shared.muted, source: "user") }
    }

    /// Resolves with `[key: change()]` or rejects with the session's failure.
    private func reply(_ call: CAPPluginCall, _ key: String, _ change: @escaping @MainActor () async throws -> Bool) {
        Task { @MainActor in
            do { call.resolve([key: try await change()]) } catch let f as VoiceSession.Failure {
                call.reject(f.message, f.code)
            } catch {
                call.reject(error.localizedDescription)
            }
        }
    }

    /// Speaker off: JARVIS replies in text only, with no speech synthesized.
    @objc func setSpeaker(_ call: CAPPluginCall) {
        guard let off = call.getBool("off") else { return call.reject("Say off: true or false.") }
        reply(call, "off") { try VoiceSession.shared.setSpeaker(off: off, source: "user") }
    }

    /// The user's answer to the post-call offer to restore the mic and speaker.
    @objc func restoreAfterCall(_ call: CAPPluginCall) {
        let restore = call.getBool("restore") ?? false
        Task { @MainActor in
            await VoiceSession.shared.restoreAfterCall(restore)
            call.resolve()
        }
    }

    @objc func sendText(_ call: CAPPluginCall) {
        guard let text = call.getString("text"), !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return call.reject("Nothing to send.")
        }
        Task { @MainActor in
            do { try VoiceSession.shared.sendText(text); call.resolve() } catch let f as VoiceSession.Failure {
                call.reject(f.message, f.code)
            } catch {
                call.reject(error.localizedDescription)
            }
        }
    }

    @objc func getStatus(_ call: CAPPluginCall) {
        Task { @MainActor in call.resolve(VoiceSession.shared.status()) }
    }

    // MARK: - Mic Mode (Voice Isolation)

    @objc func getMicMode(_ call: CAPPluginCall) {
        Task { @MainActor in call.resolve(VoiceSession.shared.micMode.state) }
    }

    /// Apps can't set the mode themselves; this opens the system picker.
    @objc func showMicModes(_ call: CAPPluginCall) {
        Task { @MainActor in
            VoiceSession.shared.micMode.show()
            call.resolve()
        }
    }

    // MARK: - Server address

    @objc func getServerUrl(_ call: CAPPluginCall) {
        let saved = ServerSettings.saved
        let url = saved ?? ServerSettings.fromBuild
        call.resolve(["url": url?.string ?? NSNull(), "fromBuild": saved == nil && url != nil])
    }

    @objc func setServerUrl(_ call: CAPPluginCall) {
        let address: ServerAddress
        do { address = try ServerAddress(call.getString("url") ?? "") } catch let p as ServerAddress.Problem {
            return call.reject(ServerAddress.message(for: p), "INVALID_URL")
        } catch {
            return call.reject(error.localizedDescription, "INVALID_URL")
        }
        ServerSettings.save(address)
        call.resolve(["url": address.string])
        load(address.origin)
    }

    @objc func clearServerUrl(_ call: CAPPluginCall) {
        ServerSettings.clear()
        call.resolve()
        loadSetup()
    }

    /// The next launch starts there directly (MainViewController).
    private func load(_ url: URL) {
        DispatchQueue.main.async { [weak self] in _ = self?.bridge?.webView?.load(URLRequest(url: url)) }
    }

    private func loadSetup() {
        guard let local = bridge?.config.localURL else { return }
        load(local)
    }

    override public func shouldOverrideLoad(_ navigationAction: WKNavigationAction) -> NSNumber? {
        guard let url = navigationAction.request.url else { return nil }
        if url.scheme == Self.scheme {
            if url.host == "setup" {
                ServerSettings.requestSetup()
                loadSetup()
            } else if let server = ServerSettings.current {  // "retry"
                load(server.origin)
            } else {
                loadSetup()
            }
            return true  // cancel the jarvis-app:// navigation itself
        }
        // allowNavigation in capacitor.config.json can't know the saved host in advance.
        if let host = url.host?.lowercased(), host == ServerSettings.current?.host { return false }
        return nil
    }

    // MARK: - Permissions

    @objc override public func checkPermissions(_ call: CAPPluginCall) {
        Task { call.resolve(["microphone": Self.micState, "notifications": await Self.notificationState()]) }
    }

    @objc override public func requestPermissions(_ call: CAPPluginCall) {
        Task {
            _ = await AVAudioApplication.requestRecordPermission()
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            call.resolve(["microphone": Self.micState, "notifications": await Self.notificationState()])
        }
    }

    private static func notificationState() async -> String {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "granted"
        case .denied: return "denied"
        default: return "prompt"
        }
    }

    private static var micState: String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        default: return "prompt"
        }
    }
}
