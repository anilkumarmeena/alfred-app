import AVFoundation
import Capacitor
import Foundation
import JarvisAudioCore
import WebKit

/// The page's handle on VoiceSession, and the server address setting. Method and event names match
/// src/definitions.ts. Links to jarvis-app://retry and jarvis-app://setup (the bundled error page) are handled
/// here too, and navigation to the saved server is allowed, since its host is only known at run time.
@objc(JarvisAudioPlugin)
public class JarvisAudioPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "JarvisAudioPlugin"
    public let jsName = "JarvisAudio"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setMuted", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "toggleMute", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sendText", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getStatus", returnType: CAPPluginReturnPromise),
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
        }
    }

    // MARK: - The session

    @objc func start(_ call: CAPPluginCall) {
        guard let passcode = call.getString("passcode"), !passcode.isEmpty else {
            return call.reject("Enter your passcode first.", "UNAUTHORIZED")
        }
        let given = call.getString("serverUrl").flatMap { try? ServerAddress($0) }
        guard let server = given ?? ServerSettings.current else {
            return call.reject("JARVIS's address isn't set.", "NO_SERVER")
        }
        let device = call.getString("device").flatMap { $0.isEmpty ? nil : $0 } ?? "iphone"
        let muted = call.getBool("muted") ?? false
        Task { @MainActor in
            do {
                call.resolve(try await VoiceSession.shared.start(server: server, passcode: passcode, device: device, muted: muted))
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
        mute(call) { try await VoiceSession.shared.setMuted(m, source: "user") }
    }

    @objc func toggleMute(_ call: CAPPluginCall) {
        mute(call) { try await VoiceSession.shared.setMuted(!VoiceSession.shared.muted, source: "user") }
    }

    private func mute(_ call: CAPPluginCall, _ change: @escaping @MainActor () async throws -> Bool) {
        Task { @MainActor in
            do { call.resolve(["muted": try await change()]) } catch let f as VoiceSession.Failure {
                call.reject(f.message, f.code)
            } catch {
                call.reject(error.localizedDescription)
            }
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

    // MARK: - The server address

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

    /// Loads the page in the running web view. The next launch starts there directly (MainViewController).
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
        // The saved server's host, which capacitor.config.json's allowNavigation can't know in advance.
        if let host = url.host?.lowercased(), host == ServerSettings.current?.host { return false }
        return nil
    }

    // MARK: - Permissions

    @objc override public func checkPermissions(_ call: CAPPluginCall) {
        call.resolve(["microphone": Self.micState, "notifications": "granted"])
    }

    @objc override public func requestPermissions(_ call: CAPPluginCall) {
        AVAudioApplication.requestRecordPermission { _ in
            call.resolve(["microphone": Self.micState, "notifications": "granted"])
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
