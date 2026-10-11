import ActivityKit
import AppIntents
import Foundation
import JarvisAudioCore

// Compiled into both the app (starts and updates the Live Activity) and JarvisWidget (draws it).

/// Nothing is fixed for the activity's lifetime; everything it shows is ContentState.
struct JarvisActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var summary: SessionSummary
        var startedAt: Date?  // nil until the room is first joined
    }
}

/// A LiveActivityIntent's perform() runs in the app's process, not the extension's, so only the app
/// (SessionActivity) sets `handler`.
enum JarvisActivityAction: Sendable {
    case setMuted(Bool), hangUp
}

@MainActor
enum JarvisActivityActions {
    static var handler: ((JarvisActivityAction) async -> Void)?
}

/// Sets an explicit state rather than toggling: a tap on Apple Watch reaches the iPhone twice.
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
