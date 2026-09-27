import Capacitor
import Foundation
import JarvisAudioCore

/// Where the app loads the JARVIS page from. Capacitor reads server.url once, when the bridge starts, so the
/// app's MainViewController calls `apply(to:)` from `instanceDescriptor()` to put the saved address in first.
/// The address is the same UserDefaults key the Settings app writes (App/Settings.bundle), so it can be
/// changed there too.
public enum ServerSettings {
    public static let urlKey = "jarvis.serverUrl"
    static let setupKey = "jarvis.showSetup"  // the next load shows the first-run page, whatever is saved

    private static var defaults: UserDefaults { .standard }

    /// The address saved in the app or typed in Settings, if it's a usable one.
    public static var saved: ServerAddress? {
        defaults.string(forKey: urlKey).flatMap { try? ServerAddress($0) }
    }

    /// server.url from capacitor.config.json: JARVIS_SERVER_URL when `npx cap sync` ran. Read once: it's bundled.
    public static let fromBuild: ServerAddress? = {
        guard let file = Bundle.main.url(forResource: "capacitor.config", withExtension: "json"),
              let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = (json["server"] as? [String: Any])?["url"] as? String else { return nil }
        return try? ServerAddress(url)
    }()

    /// What the page loads from: the saved address, else the build's.
    public static var current: ServerAddress? { saved ?? fromBuild }

    static var showSetup: Bool { defaults.bool(forKey: setupKey) }

    public static func save(_ address: ServerAddress) {
        defaults.set(address.string, forKey: urlKey)
        defaults.set(false, forKey: setupKey)
    }

    /// Forget the saved address and show the first-run page.
    public static func clear() {
        defaults.removeObject(forKey: urlKey)
        defaults.set(true, forKey: setupKey)
    }

    /// Show the first-run page, with the saved address filled in, until an address is saved.
    public static func requestSetup() {
        defaults.set(true, forKey: setupKey)
    }

    /// Points a starting bridge at the saved address (or at the bundled first-run page).
    public static func apply(to descriptor: InstanceDescriptor) {
        guard !showSetup, let address = current else {
            descriptor.serverURL = nil
            return
        }
        descriptor.serverURL = address.string  // Capacitor lets the page navigate within it
    }
}
