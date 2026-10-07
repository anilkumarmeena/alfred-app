import Foundation
import JarvisAudioCore

/// The running session for surfaces the app target draws itself: the Live Activity on the lock screen, in the
/// Dynamic Island and on Apple Watch. ActivityKit's types have to be compiled into the widget extension as well,
/// so the app owns the Activity and this hands it the session's summary and takes its buttons' presses.
@MainActor
public enum SessionControls {
    /// Called whenever what the session is doing changes, with when it started (set once the room is first
    /// joined), and with nil when the session ends.
    public static var onChange: ((SessionSummary?, Date?) -> Void)?

    private static var last: (SessionSummary?, Date?) = (nil, nil)

    /// Mutes or unmutes and plays the chime; nothing if it's that way already (a repeated tap).
    public static func setMuted(_ muted: Bool) async { await VoiceSession.shared.setMutedOffPage(muted) }

    public static func hangUp() { VoiceSession.shared.stop() }

    static func changed(_ summary: SessionSummary?, startedAt: Date?) {
        guard summary != last.0 || startedAt != last.1 else { return }
        last = (summary, startedAt)
        onChange?(summary, startedAt)
    }
}
