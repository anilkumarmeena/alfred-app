import AVFoundation
import Foundation
import MediaPlayer

/// The earphone button, two ways, both ending in `onPress`:
/// - AirPods (and some Beats) on iOS 17+: the system's mute gesture. During a playAndRecord session iOS
///   mutes or unmutes the app's input itself on a stem press, and says so with
///   AVAudioApplication.inputMuteStateChangeNotification. This is what the web page could only guess at
///   from digital silence.
/// - Wired EarPods and other headsets: the play/pause remote commands, delivered to the app that is Now
///   Playing, which a session playing JARVIS's voice is. The Now Playing card on the lock screen says what
///   JARVIS is doing, and its play/pause button mutes too.
@MainActor
final class RemoteControls {
    enum Press {
        case toggle  // a remote command: flip the mute
        case system(muted: Bool)  // the AirPods gesture: iOS already muted or unmuted the input
    }

    var onPress: ((Press) -> Void)?
    private var enabled = false
    private var observer: NSObjectProtocol?
    private let center = MPRemoteCommandCenter.shared()
    private var commands: [MPRemoteCommand] { [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand] }

    func enable() {
        guard !enabled else { return }
        enabled = true
        for command in commands {
            command.isEnabled = true
            command.addTarget { [weak self] _ in
                MainActor.assumeIsolated { self?.onPress?(.toggle) }
                return .success
            }
        }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: .main
        ) { [weak self] n in
            guard let muted = (n.userInfo?[AVAudioApplication.muteStateKey] as? NSNumber)?.boolValue else { return }
            MainActor.assumeIsolated { self?.onPress?(.system(muted: muted)) }
        }
    }

    func disable() {
        guard enabled else { return }
        enabled = false
        for command in commands {
            command.removeTarget(nil)
            command.isEnabled = false
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        setSystemMuted(false)  // stored across sessions otherwise
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// Keeps the system's input mute in step with the app's, so the next stem press goes the right way and an
    /// unmute from the screen isn't left silent.
    func setSystemMuted(_ muted: Bool) {
        guard AVAudioApplication.shared.isInputMuted != muted else { return }
        do { try AVAudioApplication.shared.setInputMuted(muted) } catch { NSLog("JarvisAudio: setInputMuted: \(error)") }
    }

    /// The lock screen's Now Playing card.
    func show(status: String, muted: Bool) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "JARVIS",
            MPMediaItemPropertyArtist: status,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: muted ? 0.0 : 1.0,
        ]
        MPNowPlayingInfoCenter.default().playbackState = muted ? .paused : .playing
    }
}
