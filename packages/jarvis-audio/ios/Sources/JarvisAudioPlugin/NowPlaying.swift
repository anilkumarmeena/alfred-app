import Foundation
import JarvisAudioCore
import MediaPlayer
import UIKit

/// The lock screen's Now Playing card during a session: "JARVIS", what it's doing (SessionSummary), the app
/// icon as artwork, and LIVE rather than a progress bar. Its play/pause button shows the mute: pause while
/// the mic is heard, play while muted (RemoteControls turns either into a mute toggle). Cleared when the
/// session ends, so nothing is left on the lock screen.
@MainActor
final class NowPlaying {
    private var shown: SessionSummary?
    private lazy var artwork: MPMediaItemArtwork? = Self.loadArtwork()

    func show(_ s: SessionSummary) {
        guard s != shown else { return }
        shown = s
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "JARVIS",
            MPMediaItemPropertyArtist: s.status,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: s.playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = s.playing ? .playing : .paused
    }

    func clear() {
        shown = nil
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    /// The app icon: the NowPlayingArtwork image in the app's asset catalog (a full-size copy of the icon, as
    /// an app icon set can't be loaded by name), else the largest compiled icon file. Nonisolated, with a
    /// @Sendable handler: MediaPlayer asks for the image off the main thread.
    private nonisolated static func loadArtwork() -> MPMediaItemArtwork? {
        let icons = (Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = icons?["CFBundleIconFiles"] as? [String] ?? []
        guard let image = UIImage(named: "NowPlayingArtwork") ?? files.reversed().lazy.compactMap({ UIImage(named: $0) }).first else {
            NSLog("JarvisAudio: no Now Playing artwork")
            return nil
        }
        return MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }
}
