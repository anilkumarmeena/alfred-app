import Foundation

/// A typed JARVIS address (`mac.tailnet.ts.net`, `http://localhost:8787`…) reduced to its origin; the page lives at `/`.
public struct ServerAddress: Equatable, Sendable {
    public let origin: URL

    public enum Problem: Error, Equatable {
        case empty
        case unsupportedScheme(String)
        case noHost
    }

    public init(_ text: String) throws {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw Problem.empty }
        if !s.contains("://") { s = "https://" + s }  // Tailscale Serve is HTTPS
        guard var parts = URLComponents(string: s) else { throw Problem.noHost }
        let scheme = (parts.scheme ?? "").lowercased()
        guard scheme == "https" || scheme == "http" else { throw Problem.unsupportedScheme(scheme) }
        guard let host = parts.host, !host.isEmpty else { throw Problem.noHost }
        parts.scheme = scheme
        parts.host = host.lowercased()
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        parts.user = nil
        parts.password = nil
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        guard let url = parts.url else { throw Problem.noHost }
        origin = url
    }

    public var string: String { origin.absoluteString }
    public var host: String { origin.host ?? "" }

    /// POST {"passcode", "device"} → {"token", "url"}.
    public var tokenURL: URL { origin.appendingPathComponent("api/token") }

    /// POST {"passcode", "device", "token", "environment", "topic"}.
    public var pushURL: URL { origin.appendingPathComponent("api/push/native") }

    /// A notification's page on this server, with title and body in the fragment as the service worker puts them
    /// (#title=…&body=…). Nil for another host, so a notification can't point the web view elsewhere.
    public func page(_ url: String, title: String? = nil, body: String? = nil) -> URL? {
        guard let resolved = URL(string: url, relativeTo: origin)?.absoluteURL,
              var parts = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == origin.scheme,
              parts.host?.lowercased() == host,
              parts.port == URLComponents(url: origin, resolvingAgainstBaseURL: false)?.port else { return nil }
        let items = [("title", title), ("body", body)].compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        if !items.isEmpty {
            var hash = URLComponents()
            hash.queryItems = items
            // The page reads it with URLSearchParams, where a plain + is a space.
            parts.percentEncodedFragment = hash.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return parts.url
    }

    /// iOS allows plain http only for local addresses.
    public var isCleartext: Bool { origin.scheme == "http" }

    public static func message(for problem: Problem) -> String {
        switch problem {
        case .empty: return "Enter JARVIS's address."
        case .unsupportedScheme(let s): return "\(s):// isn't a web address. Use https://."
        case .noHost: return "That doesn't look like an address. Try https://your-computer.your-tailnet.ts.net."
        }
    }
}
