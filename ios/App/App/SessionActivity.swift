import ActivityKit
import Foundation
import JarvisAudioCore
import JarvisAudioPlugin
import os

private let log = Logger(subsystem: "com.anil.jarvis", category: "liveactivity")

/// The Live Activity on the lock screen, in the Dynamic Island and on Apple Watch while a session runs: what
/// JARVIS is doing, how long the session has been going, and Mute/Unmute and Hang Up buttons (JarvisWidget
/// draws it). It follows SessionControls and ends with the session.
@MainActor
final class SessionActivity {
    static let shared = SessionActivity()

    private var activity: Activity<JarvisActivityAttributes>?
    private var dismissed = false  // swiped away: not brought back until the next session
    private var queue: Task<Void, Never>?  // updates and ends run one after another
    private var latest = 0  // the newest update: older ones still waiting are dropped

    func install() {
        JarvisActivityActions.handler = { action in
            log.notice("button \(String(describing: action), privacy: .public)")
            switch action {
            case .setMuted(let m): await SessionControls.setMuted(m)
            case .hangUp: SessionControls.hangUp()
            }
        }
        SessionControls.onChange = { [weak self] in self?.show($0, startedAt: $1) }
        // Left over from a launch that was killed mid-session: no session is running now. Listed here, before
        // any session can start, so a new session's activity is never among them.
        for a in Activity<JarvisActivityAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// The app is being quit (swiped away in the app switcher; a session keeps it running in the background, so
    /// iOS says so first). iOS leaves a quit app's Live Activities up, so end the card before the process goes,
    /// waiting up to two seconds. A crash or a kill without warning leaves it until the next launch.
    static nonisolated func endBeforeQuit() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for a in Activity<JarvisActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
            done.signal()
        }
        if done.wait(timeout: .now() + 2) == .timedOut { log.error("quit: the Live Activity didn't end in time") }
    }

    private func show(_ summary: SessionSummary?, startedAt: Date?) {
        guard let summary else { return end() }
        let content = ActivityContent(state: JarvisActivityAttributes.ContentState(summary: summary, startedAt: startedAt), staleDate: nil)
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
            // Only allowed with the app on screen, which it is when a session starts; if it isn't, the next
            // change tries again.
            do {
                activity = try Activity.request(attributes: JarvisActivityAttributes(), content: content)
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
