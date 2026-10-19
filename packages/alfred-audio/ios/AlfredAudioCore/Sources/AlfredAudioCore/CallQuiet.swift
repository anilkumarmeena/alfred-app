import Foundation

/// Any CallKit call (phone, FaceTime, WhatsApp…) turns Alfred's mic and speaker off so it neither hears the call nor
/// talks over it. When the last call ends, the page offers to restore the pre-call state if it differs.
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
    /// Open from the call's end until the user answers or changes the mic or speaker themselves.
    public private(set) var offer: State?

    public init() {}

    /// True only for the first concurrent call, when the mic and speaker should go off.
    public mutating func began(_ now: State) -> Bool {
        offer = nil
        guard before == nil else { return false }
        before = now
        return true
    }

    /// The last call ended: the state to offer back, or nil if `now` already matches it.
    public mutating func ended(_ now: State) -> State? {
        guard let was = before else { return nil }
        before = nil
        offer = was == now ? nil : was
        return offer
    }

    /// Closes the offer (answered, or the user changed the mic or speaker) and returns it if one was open.
    @discardableResult
    public mutating func settle() -> State? {
        defer { offer = nil }
        return offer
    }
}
