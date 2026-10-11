import Foundation

/// Keeps the LiveKit mic track in step with what the page shows: the user's mute and an audio interruption (call,
/// Siri, alarm). When the room reports the mic doing something else, the app's state is what gets corrected.
public struct MicSync: Sendable {
    /// For this long after a change, room reports may still describe the old mic state.
    public var settle: TimeInterval
    private var changedAt: TimeInterval = -.infinity

    public init(settle: TimeInterval = 2) {
        self.settle = settle
    }

    /// Desired track state, or nil to leave it. During an interruption iOS holds the input, so the track is only
    /// ever switched off then (a mute must still stop it) and comes back on afterwards.
    public static func target(muted: Bool, interrupted: Bool) -> Bool? {
        muted ? false : interrupted ? nil : true
    }

    /// `now` is seconds on any monotonic clock.
    public mutating func changed(at now: TimeInterval) {
        changedAt = now
    }

    public func settled(at now: TimeInterval) -> Bool {
        now - changedAt >= settle
    }

    public struct Fix: Equatable, Sendable {
        /// iOS never reported the interruption's end, but the mic is back.
        public var interruptionOver = false
        /// The track is sending although the user muted it.
        public var muteAgain = false

        public init(interruptionOver: Bool = false, muteAgain: Bool = false) {
            self.interruptionOver = interruptionOver
            self.muteAgain = muteAgain
        }
    }

    /// The server heard this mic, so it is live. iOS doesn't always report an interruption's end, so any the app
    /// still believes in is over; a mute that didn't reach the track is reapplied.
    public func heard(at now: TimeInterval, muted: Bool, interrupted: Bool) -> Fix {
        guard settled(at: now) else { return Fix() }
        return Fix(interruptionOver: interrupted, muteAgain: muted)
    }
}
