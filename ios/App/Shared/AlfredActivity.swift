import ActivityKit
import AppIntents
import Foundation
import AlfredAudioCore

// Compiled into both the app (starts and updates the Live Activity) and AlfredWidget (draws it).

/// Nothing is fixed for the activity's lifetime; everything it shows is ContentState.
struct AlfredActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var summary: SessionSummary
        var startedAt: Date?  // nil until the room is first joined
    }
}

/// A LiveActivityIntent's perform() runs in the app's process, not the extension's, so only the app
/// (SessionActivity) sets `handler`.
enum AlfredActivityAction: Sendable {
    case setMuted(Bool), hangUp
}

@MainActor
enum AlfredActivityActions {
    static var handler: ((AlfredActivityAction) async -> Void)?
}

/// Sets an explicit state rather than toggling: a tap on Apple Watch reaches the iPhone twice.
struct SetMutedIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute or Unmute Alfred"
    static let isDiscoverable = false  // only the Live Activity's button, not Shortcuts or Siri

    @Parameter(title: "Muted")
    var muted: Bool

    init() {}
    init(muted: Bool) { self.muted = muted }

    @MainActor
    func perform() async throws -> some IntentResult {
        await AlfredActivityActions.handler?(.setMuted(muted))
        return .result()
    }
}

struct HangUpIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Hang Up Alfred"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await AlfredActivityActions.handler?(.hangUp)
        return .result()
    }
}
