import Foundation

/// The session's state in a word, shown by the Live Activity; derived from VoiceSession so every surface agrees.
public struct SessionSummary: Codable, Hashable, Sendable {  // Codable: the Live Activity's content carries it
    public enum Phase: String, Codable, Sendable {
        case connecting, reconnecting, interrupted, muted, speaking, thinking, listening
    }

    public let phase: Phase
    public let muted: Bool

    /// `connection` and `agentState` as VoiceSession keeps them; nil when no session is active.
    public init?(active: Bool, connection: String, agentState: String?, muted: Bool, interrupted: Bool) {
        guard active else { return nil }
        self.muted = muted
        switch connection {
        case "connecting": phase = .connecting
        case "reconnecting": phase = .reconnecting
        default:
            if interrupted { phase = .interrupted }
            else if muted { phase = .muted }
            else if agentState == "speaking" { phase = .speaking }
            else if agentState == "thinking" { phase = .thinking }
            else { phase = .listening }
        }
    }

    public var status: String {
        switch phase {
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .interrupted: return "Mic paused for a call"
        case .muted: return "Muted"
        case .speaking: return "Speaking"
        case .thinking: return "Thinking"
        case .listening: return "Listening"
        }
    }
}
