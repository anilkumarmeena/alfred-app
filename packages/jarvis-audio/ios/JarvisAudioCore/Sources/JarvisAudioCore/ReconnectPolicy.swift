import Foundation

/// Backoff for rejoining with a fresh token once LiveKit's own resume (ICE restart, signal reconnect) gives up.
/// Retries forever while the session is wanted; a network change skips the wait.
public struct ReconnectPolicy: Sendable {
    public var delays: [TimeInterval]
    /// Random extra fraction of each delay, so several devices don't retry in step.
    public var jitter: Double

    public init(delays: [TimeInterval] = [1, 2, 4, 8, 15, 30], jitter: Double = 0.2) {
        self.delays = delays
        self.jitter = jitter
    }

    /// `attempt` counts from 1; `random` is in 0..<1.
    public func delay(attempt: Int, random: Double = Double.random(in: 0..<1)) -> TimeInterval {
        guard let last = delays.last else { return 0 }
        let base = attempt >= 1 && attempt <= delays.count ? delays[attempt - 1] : last
        return base + base * jitter * min(max(random, 0), 1)
    }
}

/// Why a room went away, reduced to what decides whether to rejoin it.
public enum DisconnectCause: Equatable, Sendable {
    case clientInitiated  // we left
    case agentLeft  // JARVIS ended the session
    case network  // the connection was lost
    case removed  // the server removed us, deleted the room or shut down
    case duplicateIdentity
    case unknown

    /// Only when nobody meant the session to end.
    public var shouldReconnect: Bool {
        switch self {
        case .network, .unknown: return true
        case .clientInitiated, .agentLeft, .removed, .duplicateIdentity: return false
        }
    }
}
