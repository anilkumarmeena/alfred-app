import ActivityKit
import AppIntents
import Foundation
import JarvisAudioCore

// Compiled into both the app and the JarvisWidget extension: the app starts and updates the Live Activity, the
// extension draws it, and both need the same types for that.

/// The Live Activity during a session. Nothing is fixed for its lifetime; everything it shows is ContentState.
struct JarvisActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var summary: SessionSummary
        var startedAt: Date?  // nil until the room is first joined
    }
}

/// What the Live Activity's buttons ask the app to do. A LiveActivityIntent's perform() runs in the app's
/// process, not the extension's, so the app (SessionActivity) sets `handler` and the extension never needs it.
enum JarvisActivityAction: Sendable {
    case setMuted(Bool), hangUp
}

@MainActor
enum JarvisActivityActions {
    static var handler: ((JarvisActivityAction) async -> Void)?
}

/// Mute or unmute, to the state the button asked for rather than a toggle: a tap on Apple Watch reaches the
/// iPhone twice, and a toggle run twice would undo itself.
struct SetMutedIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute or Unmute JARVIS"
    static let isDiscoverable = false  // only the Live Activity's button, not Shortcuts or Siri

    @Parameter(title: "Muted")
    var muted: Bool

    init() {}
    init(muted: Bool) { self.muted = muted }

    @MainActor
    func perform() async throws -> some IntentResult {
        await JarvisActivityActions.handler?(.setMuted(muted))
        return .result()
    }
}

struct HangUpIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Hang Up JARVIS"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await JarvisActivityActions.handler?(.hangUp)
        return .result()
    }
}
