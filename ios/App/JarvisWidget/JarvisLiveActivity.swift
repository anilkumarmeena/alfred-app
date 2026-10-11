import ActivityKit
import AppIntents
import JarvisAudioCore
import SwiftUI
import WidgetKit

/// Lock screen, Dynamic Island and Apple Watch Smart Stack. Watch button taps run on the iPhone.
struct JarvisLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JarvisActivityAttributes.self) { context in
            ActivityView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(state: state).font(.title2).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text("JARVIS").font(.headline)
                        StatusLine(state: state).font(.subheadline)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Buttons(state: state).padding(.top, 6)
                }
            } compactLeading: {
                PhaseIcon(state: state)
            } compactTrailing: {
                Elapsed(state: state).frame(maxWidth: 44).font(.caption.monospacedDigit())
            } minimal: {
                PhaseIcon(state: state)
            }
            .keylineTint(.cyan)
        }
        .supplementalActivityFamilies([.small])  // a watch layout instead of the Dynamic Island's compact pieces
    }
}

private struct ActivityView: View {
    let state: JarvisActivityAttributes.ContentState
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small: WatchView(state: state)
        default: LockScreenView(state: state)
        }
    }
}

private struct WatchView: View {
    let state: JarvisActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PhaseIcon(state: state)
                Text("JARVIS").font(.headline).foregroundStyle(.white)
                Spacer(minLength: 4)
                Elapsed(state: state).font(.caption2).foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 6) {
                Text(state.summary.status).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                Spacer(minLength: 4)
                Buttons(state: state, compact: true)
            }
        }
        .padding(10)
    }
}

private struct LockScreenView: View {
    let state: JarvisActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            PhaseIcon(state: state)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text("JARVIS").font(.headline).foregroundStyle(.white)
                StatusLine(state: state).font(.subheadline)
            }
            Spacer(minLength: 8)
            Buttons(state: state, compact: true)
        }
        .padding(16)
    }
}

/// "Listening · 4:12", timed from the first join.
private struct StatusLine: View {
    let state: JarvisActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 4) {
            Text(state.summary.status)
            if state.startedAt != nil {
                Text("·")
                Elapsed(state: state)
            }
        }
        .foregroundStyle(.white.opacity(0.7))
        .lineLimit(1)
    }
}

private struct Elapsed: View {
    let state: JarvisActivityAttributes.ContentState

    var body: some View {
        if let start = state.startedAt {
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Never a mic symbol, so it can't be mistaken for the Mute button.
private struct PhaseIcon: View {
    let state: JarvisActivityAttributes.ContentState

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeat(.continuous), isActive: state.summary.phase == .speaking)
            .contentTransition(.symbolEffect(.replace))
    }

    private var symbol: String {
        switch state.summary.phase {
        case .connecting, .reconnecting: return "antenna.radiowaves.left.and.right"
        case .interrupted: return "phone.fill"
        case .muted: return "waveform.slash"
        case .speaking: return "speaker.wave.2.fill"
        case .thinking: return "ellipsis"
        case .listening: return "waveform"
        }
    }

    private var color: Color {
        switch state.summary.phase {
        case .muted: return .gray
        case .interrupted: return .orange
        case .connecting, .reconnecting: return .yellow
        case .speaking, .thinking, .listening: return .cyan
        }
    }
}

/// LiveActivityIntents run in the app, which is alive for the whole session.
private struct Buttons: View {
    let state: JarvisActivityAttributes.ContentState
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 10 : 12) {
            Button(intent: SetMutedIntent(muted: !state.summary.muted)) {
                label(state.summary.muted ? "Unmute" : "Mute", state.summary.muted ? "mic.slash.fill" : "mic.fill")
            }
            .tint(state.summary.muted ? .orange : .white.opacity(0.25))
            .foregroundStyle(.white)

            Button(intent: HangUpIntent()) {
                label("End", "phone.down.fill")
            }
            .tint(.red)
            .foregroundStyle(.white)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
    }

    @ViewBuilder
    private func label(_ title: String, _ symbol: String) -> some View {
        if compact {
            Image(systemName: symbol).font(.title3).frame(width: 28, height: 28)
        } else {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
        }
    }
}
