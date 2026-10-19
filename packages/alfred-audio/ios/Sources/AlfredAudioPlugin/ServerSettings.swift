import Capacitor
import Foundation
import AlfredAudioCore

/// Where the app loads the Alfred page from. Capacitor reads server.url once at bridge start, so
/// MainViewController calls `apply(to:)` from `instanceDescriptor()`. The key is shared with Settings.bundle.
public enum ServerSettings {
    public static let urlKey = "jarvis.serverUrl"
    static let setupKey = "jarvis.showSetup"  // next load shows the first-run page, whatever is saved

    private static var defaults: UserDefaults { .standard }

    public static var saved: ServerAddress? {
        defaults.string(forKey: urlKey).flatMap { try? ServerAddress($0) }
    }

    /// server.url from the bundled capacitor.config.json (ALFRED_SERVER_URL at `npx cap sync` time).
    public static let fromBuild: ServerAddress? = {
        guard let file = Bundle.main.url(forResource: "capacitor.config", withExtension: "json"),
              let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = (json["server"] as? [String: Any])?["url"] as? String else { return nil }
        return try? ServerAddress(url)
    }()

    public static var current: ServerAddress? { saved ?? fromBuild }

    static var showSetup: Bool { defaults.bool(forKey: setupKey) }

    public static func save(_ address: ServerAddress) {
        defaults.set(address.string, forKey: urlKey)
        defaults.set(false, forKey: setupKey)
    }

    public static func clear() {
        defaults.removeObject(forKey: urlKey)
        defaults.set(true, forKey: setupKey)
    }

    /// Shows the first-run page, saved address prefilled, until an address is saved.
    public static func requestSetup() {
        defaults.set(true, forKey: setupKey)
    }

    /// Nil serverURL loads the bundled first-run page.
    public static func apply(to descriptor: InstanceDescriptor) {
        guard !showSetup, let address = current else {
            descriptor.serverURL = nil
            return
        }
        descriptor.serverURL = address.string  // Capacitor keeps navigation within this origin
    }
}
