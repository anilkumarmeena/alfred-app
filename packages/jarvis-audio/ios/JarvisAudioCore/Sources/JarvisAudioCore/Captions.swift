import Foundation

/// The agent's lk.agent.state attribute, checked against the states the page knows.
public enum AgentStates {
    public static let known: Set<String> = ["initializing", "idle", "listening", "thinking", "speaking"]

    public static func parse(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespaces).lowercased(), known.contains(v) else { return nil }
        return v
    }
}

/// lk.transcription segments arrive in chunks; the page gets the whole line so far each time. A resent segment
/// starts over, matching the page.
public struct Captions: Sendable {
    public struct Line: Equatable, Sendable {
        public let id: String
        public let speaker: String  // "you" or "jarvis"
        public let text: String
        public let final: Bool
    }

    private var texts: [String: String] = [:]
    private var order: [String] = []
    private let limit: Int

    public init(limit: Int = 100) {
        self.limit = limit
    }

    /// Empties the line if `id` was seen before.
    public mutating func begin(id: String) {
        if texts[id] == nil { order.append(id) }
        texts[id] = ""
        while order.count > limit { texts.removeValue(forKey: order.removeFirst()) }
    }

    public mutating func append(id: String, chunk: String, speaker: String, final: Bool = false) -> Line {
        if texts[id] == nil { begin(id: id) }
        let text = (texts[id] ?? "") + chunk
        texts[id] = text
        return Line(id: id, speaker: speaker, text: text, final: final)
    }

    public func text(id: String) -> String? { texts[id] }

    /// Same test as the page: our own identity is the user, anyone else is JARVIS.
    public static func speaker(sender: String?, local: String?) -> String {
        sender != nil && sender == local ? "you" : "jarvis"
    }
}
