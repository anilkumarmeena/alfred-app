import ActivityKit
import Foundation
import AlfredAudioCore
import AlfredAudioPlugin
import os

private let log = Logger(subsystem: "com.anil.jarvis", category: "liveactivity")

/// Drives the session's Live Activity (drawn by AlfredWidget) from SessionControls; ends with the session.
@MainActor
final class SessionActivity {
    static let shared = SessionActivity()

    private var activity: Activity<AlfredActivityAttributes>?
    private var dismissed = false  // swiped away: not brought back until the next session
    private var queue: Task<Void, Never>?  // updates and ends run one after another
    private var latest = 0  // the newest update: older ones still waiting are dropped

    func install() {
        AlfredActivityActions.handler = { action in
            log.notice("button \(String(describing: action), privacy: .public)")
            switch action {
            case .setMuted(let m): await SessionControls.setMuted(m)
            case .hangUp: SessionControls.hangUp()
            }
        }
        SessionControls.onChange = { [weak self] in self?.show($0, startedAt: $1) }
        // Leftovers from a launch killed mid-session. Ended here, before any session can start, so a new
        // session's activity is never among them.
        for a in Activity<AlfredActivityAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// iOS leaves a quit app's Live Activities up, so end them before the process goes (blocks up to 2 s).
    /// A crash or kill without warning leaves the card until the next launch.
    static nonisolated func endBeforeQuit() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for a in Activity<AlfredActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
            done.signal()
        }
        if done.wait(timeout: .now() + 2) == .timedOut { log.error("quit: the Live Activity didn't end in time") }
    }

    private func show(_ summary: SessionSummary?, startedAt: Date?) {
        guard let summary else { return end() }
        let content = ActivityContent(state: AlfredActivityAttributes.ContentState(summary: summary, startedAt: startedAt), staleDate: nil)
        if let a = activity, a.activityState == .dismissed || a.activityState == .ended {
            activity = nil
            dismissed = true
        }
        if let a = activity {
            latest += 1
            let n = latest
            enqueue { [weak self] in
                guard n == self?.latest else { return }  // a newer state is queued behind this one
                await a.update(content)
            }
        } else if !dismissed, ActivityAuthorizationInfo().areActivitiesEnabled {
            // Only allowed while the app is in the foreground; if it isn't, the next change retries.
            do {
                activity = try Activity.request(attributes: AlfredActivityAttributes(), content: content)
            } catch {
                log.error("request: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func end() {
        dismissed = false
        guard let a = activity else { return }
        activity = nil
        latest += 1  // updates still waiting for this activity are dropped
        enqueue { await a.end(nil, dismissalPolicy: .immediate) }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { await previous?.value; await work() }
    }
}
