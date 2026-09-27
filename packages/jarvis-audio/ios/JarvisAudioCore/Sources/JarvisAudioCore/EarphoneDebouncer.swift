import Foundation

/// One earphone press can arrive more than once: as the AirPods mute gesture and as a remote command, or as
/// both pause and togglePlayPause from a wired headset. Only the first within `window` seconds counts.
public struct EarphoneDebouncer: Sendable {
    public var window: TimeInterval
    private var last: TimeInterval?

    public init(window: TimeInterval = 0.4) {
        self.window = window
    }

    /// Whether a press at `now` (seconds, any monotonic clock) is a new one.
    public mutating func accept(at now: TimeInterval) -> Bool {
        if let last, now - last >= 0, now - last < window { return false }
        last = now
        return true
    }

    public mutating func reset() { last = nil }
}
