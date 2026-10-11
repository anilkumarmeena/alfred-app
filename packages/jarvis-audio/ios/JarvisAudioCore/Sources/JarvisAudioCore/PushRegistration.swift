import Foundation

/// Registers the APNs token with jarvis.web's /api/push/native so JARVIS can reach the phone while the app is
/// closed. The page's Web Push doesn't work in an app's web view.
public enum PushRegistration {
    public enum Refusal: Error, Equatable {
        case unauthorized  // 401: wrong passcode
        case notSupported  // 404: the JARVIS server has no /api/push/native yet
        case off(String)  // 409: notifications are off on the JARVIS computer (JARVIS_PUSH)
        case server(String)

        public var message: String {
            switch self {
            case .unauthorized: return "Wrong passcode."
            case .notSupported: return "The JARVIS computer doesn't take app notifications yet (no /api/push/native)."
            case .off(let m), .server(let m): return m
            }
        }
    }

    /// Hex, as the APNs HTTP API takes it in the path.
    public static func tokenString(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// APNs environment from embedded.mobileprovision: "development" (sandbox) for Xcode device builds,
    /// "production" for TestFlight and the App Store, which ship no profile.
    public static func environment(provisioningProfile: Data?) -> String {
        guard let profile = provisioningProfile else { return "production" }
        // The profile is a signed CMS message with the plist inside it as plain text.
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: profile[start.lowerBound..<end.upperBound], format: nil),
              let entitlements = (plist as? [String: Any])?["Entitlements"] as? [String: Any],
              let env = entitlements["aps-environment"] as? String else { return "development" }
        return env == "production" ? "production" : "development"
    }

    /// `topic` is the app's bundle id.
    public static func body(passcode: String, device: String, token: String, environment: String, topic: String) -> Data {
        let json = ["passcode": passcode, "device": device, "token": token, "environment": environment, "topic": topic]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    public static func parse(status: Int, body: Data) -> Result<Void, Refusal> {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let said = (json?["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch status {
        case 200: return .success(())
        case 401: return .failure(.unauthorized)
        case 404, 405: return .failure(.notSupported)
        case 409: return .failure(.off(said ?? "Notifications are off on the JARVIS computer."))
        default: return .failure(.server(said ?? "JARVIS didn't take the notification token (HTTP \(status))."))
        }
    }
}
