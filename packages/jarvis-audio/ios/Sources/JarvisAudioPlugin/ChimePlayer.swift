import AVFoundation
import JarvisAudioCore

/// Plays the earphone cue (JarvisAudioCore.Chime) on the session's route, over whatever JARVIS is saying.
@MainActor
final class ChimePlayer {
    private lazy var players: [Bool: AVAudioPlayer] = {
        var p: [Bool: AVAudioPlayer] = [:]
        for muted in [true, false] {
            if let player = try? AVAudioPlayer(data: Chime.wav(muted: muted)) {
                player.prepareToPlay()
                p[muted] = player
            }
        }
        return p
    }()

    func play(muted: Bool) {
        guard let player = players[muted] else { return }
        player.currentTime = 0
        player.play()
    }
}
