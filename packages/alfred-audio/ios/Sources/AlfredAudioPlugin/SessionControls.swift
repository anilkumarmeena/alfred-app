import Foundation
import AlfredAudioCore

/// Session state and controls for the app target's Live Activity. ActivityKit types must also compile into the
/// widget extension, so the app owns the Activity rather than this plugin.
@MainActor
public enum SessionControls {
    /// Start date is set once the room is first joined; summary is nil when the session ends.
    public static var onChange: ((SessionSummary?, Date?) -> Void)?

    private static var last: (SessionSummary?, Date?) = (nil, nil)

    /// Plays the chime; a no-op if already in that state (a repeated tap).
    public static func setMuted(_ muted: Bool) async { await VoiceSession.shared.setMutedOffPage(muted) }

    public static func hangUp() { VoiceSession.shared.stop() }

    static func changed(_ summary: SessionSummary?, startedAt: Date?) {
        guard summary != last.0 || startedAt != last.1 else { return }
        last = (summary, startedAt)
        onChange?(summary, startedAt)
    }
}
