import Foundation

/// What jarvis.web's /api/token gives back: a LiveKit token and the URL to join with it.
public struct Grant: Equatable, Sendable {
    public let token: String
    public let url: String
}

/// Why /api/token didn't give a grant. The messages are the page's own, so the app says the same things.
public enum TokenError: Error, Equatable {
    case unauthorized  // 401: wrong passcode
    case rateLimited(String)  // 429: too many wrong passcodes lately
    case server(String)  // anything else the server said no to
    case badReply

    public var message: String {
        switch self {
        case .unauthorized: return "Wrong passcode."
        case .rateLimited(let m), .server(let m): return m
        case .badReply: return "Couldn't reach JARVIS."
        }
    }

    /// The failure code the plugin reports, as in its TypeScript definitions.
    public var code: String {
        switch self {
        case .unauthorized: return "UNAUTHORIZED"
        case .rateLimited: return "RATE_LIMITED"
        case .server, .badReply: return "SERVER"
        }
    }

    /// Worth trying again later without the user: a server hiccup, not a refusal.
    public var isRetryable: Bool {
        switch self {
        case .unauthorized, .rateLimited: return false
        case .server, .badReply: return true
        }
    }
}

public enum TokenReply {
    /// The request body, as the page sends it.
    public static func body(passcode: String, device: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["passcode": passcode, "device": device])) ?? Data()
    }

    public static func parse(status: Int, body: Data) -> Result<Grant, TokenError> {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let said = (json?["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch status {
        case 200:
            guard let token = json?["token"] as? String, !token.isEmpty,
                  let url = json?["url"] as? String, !url.isEmpty else { return .failure(.badReply) }
            return .success(Grant(token: token, url: url))
        case 401: return .failure(.unauthorized)
        case 429: return .failure(.rateLimited(said ?? "Too many wrong passcodes. Try again in a few minutes."))
        default: return .failure(.server(said ?? "Couldn't reach JARVIS (HTTP \(status))."))
        }
    }
}
