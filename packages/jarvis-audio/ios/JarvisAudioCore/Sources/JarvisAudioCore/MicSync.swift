import Foundation

/// Keeps the mic track and what the page shows in step. Two things decide whether the user is heard: their mute
/// (the screen, the earphone button, the lock screen) and an interruption (a call, Siri or an alarm holding the
/// audio). The page shows those two ("Muted", "Mic paused"), so the LiveKit track has to follow them after every
/// change, reconnect and interruption, and when the room says the mic is doing something else, the app's own
/// state is what gets corrected.
public struct MicSync: Sendable {
    /// For this long after a change, what the room reports can still be about the mic as it was before.
    public var settle: TimeInterval
    private var changedAt: TimeInterval = -.infinity

    public init(settle: TimeInterval = 2) {
        self.settle = settle
    }

    /// What the mic track should be switched to now, or nil to leave it as it is: on unless the user muted it.
    /// During an interruption it's only ever switched off (a mute then still has to stop it): iOS holds the input
    /// itself until the call or Siri is over, and the track is switched back on after that.
    public static func target(muted: Bool, interrupted: Bool) -> Bool? {
        muted ? false : interrupted ? nil : true
    }

    /// The mute or the interruption changed at `now` (seconds, any monotonic clock).
    public mutating func changed(at now: TimeInterval) {
        changedAt = now
    }

    /// Whether reports from the room at `now` describe the mic as the app has it now.
    public func settled(at now: TimeInterval) -> Bool {
        now - changedAt >= settle
    }

    public struct Fix: Equatable, Sendable {
        /// The interruption is over, though iOS never said so: the mic is back.
        public var interruptionOver = false
        /// The track is sending although the user muted it: mute it again.
        public var muteAgain = false

        public init(interruptionOver: Bool = false, muteAgain: Bool = false) {
            self.interruptionOver = interruptionOver
            self.muteAgain = muteAgain
        }
    }

    /// The server heard this device's mic at `now`, which only happens while the mic is live and sending. iOS
    /// doesn't promise an end to every interruption it starts, so one the app still thinks is going on is over;
    /// and a mute that didn't reach the track is applied again.
    public func heard(at now: TimeInterval, muted: Bool, interrupted: Bool) -> Fix {
        guard settled(at: now) else { return Fix() }
        return Fix(interruptionOver: interrupted, muteAgain: muted)
    }
}
