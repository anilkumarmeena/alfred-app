import Foundation

/// What the session is doing, in a word for the user: the Live Activity on the lock screen, in the Dynamic
/// Island and on the watch shows it under "JARVIS". Built from VoiceSession's state, so every surface outside
/// the page says the same.
public struct SessionSummary: Codable, Hashable, Sendable {  // Codable: the Live Activity's content carries it
    public enum Phase: String, Codable, Sendable {
        case connecting, reconnecting, interrupted, muted, speaking, thinking, listening
    }

    public let phase: Phase
    public let muted: Bool

    /// connection and agentState as VoiceSession keeps them ("connecting", "reconnecting", "connected"…; an
    /// lk.agent.state value or nil). nil with no session.
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
