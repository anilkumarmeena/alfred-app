import Foundation

/// What the session is doing, in a word for the user: the lock screen's Now Playing card shows it under
/// "JARVIS", and a Live Activity can show the same thing. Built from VoiceSession's state, so every surface
/// outside the page says the same.
public struct SessionSummary: Equatable, Sendable {
    public enum Phase: String, Sendable {
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

    /// Whether the mic is meant to be heard: Now Playing shows it as playing (a pause button, which mutes) or
    /// paused (a play button, which unmutes). It follows the user's mute only, so the button always does what
    /// it shows, even while connecting or in a call.
    public var playing: Bool { !muted }
}
