import Foundation

/// A phone call (or any CallKit call: FaceTime, WhatsApp…) turns JARVIS's mic and speaker off, so nothing of the call
/// is heard by JARVIS and JARVIS says nothing over it. When the last call ends, the user is offered the mic and the
/// speaker back as they were before it, if that's any different; VoiceSession asks the page, which shows the offer.
public struct CallQuiet: Equatable, Sendable {
    public struct State: Equatable, Sendable {
        public var muted: Bool
        public var speakerOff: Bool

        public init(muted: Bool, speakerOff: Bool) {
            self.muted = muted
            self.speakerOff = speakerOff
        }
    }

    private var before: State?  // as it was when the first call came in, until the last one ends
    /// What to offer to put back, from the end of the call until the user answers or changes either themselves.
    public private(set) var offer: State?

    public init() {}

    /// A call is ringing or on, as the session is `now`. True the first time, when the mic and speaker go off; a
    /// second call during the first changes nothing.
    public mutating func began(_ now: State) -> Bool {
        offer = nil
        guard before == nil else { return false }
        before = now
        return true
    }

    /// The last call ended, leaving the session `now`: what to offer to put back, or nil if it's as it was before.
    public mutating func ended(_ now: State) -> State? {
        guard let was = before else { return nil }
        before = nil
        offer = was == now ? nil : was
        return offer
    }

    /// The user answered the offer, or set the mic or speaker themselves: the offer is closed. Returns it, if one was
    /// open.
    @discardableResult
    public mutating func settle() -> State? {
        defer { offer = nil }
        return offer
    }
}
