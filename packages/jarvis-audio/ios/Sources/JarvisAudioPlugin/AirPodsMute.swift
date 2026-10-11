import AVFoundation
import Foundation
import os

let muteLog = Logger(subsystem: "com.anil.jarvis", category: "mute")

/// AirPods (and some Beats) stem-press mute. During playAndRecord iOS mutes the input itself and posts
/// inputMuteStateChangeNotification. Adding that observer is what opts in: iOS marks every audio session that
/// exists at that moment (PrefersBluetoothAccessoryMuting). A session created later stays unmarked and a press
/// gets "Cannot control mic with AirPods", so optIn() re-adds the observer once the mic is recording and all the
/// engine's sessions exist.
@MainActor
final class AirPodsMute {
    /// iOS has already muted or unmuted the input.
    var onPress: ((_ muted: Bool) -> Void)?
    private var observer: NSObjectProtocol?
    private var echo: Bool?  // set by setSystemMuted so its own notification is dropped

    init() { optIn() }

    /// Re-adding the observer opts in every audio session that exists now.
    func optIn() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: .main
        ) { [weak self] n in
            guard let muted = (n.userInfo?[AVAudioApplication.muteStateKey] as? NSNumber)?.boolValue else { return }
            MainActor.assumeIsolated { self?.systemMuteChanged(muted) }
        }
        muteLog.info("observing inputMuteStateChange; isInputMuted=\(AVAudioApplication.shared.isInputMuted, privacy: .public) input=\(Self.inputRoute, privacy: .public)")
    }

    private func systemMuteChanged(_ muted: Bool) {
        let isEcho = echo == muted
        echo = nil
        let now = AVAudioApplication.shared.isInputMuted, input = Self.inputRoute
        muteLog.info("""
            inputMuteStateChange muted=\(muted, privacy: .public) isInputMuted=\(now, privacy: .public) \
            input=\(input, privacy: .public) echo=\(isEcho, privacy: .public)
            """)
        if !isEcho { onPress?(muted) }
    }

    /// For logs: BluetoothHFP is a headset mic, MicrophoneBuiltIn the phone.
    static var inputRoute: String {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        return inputs.isEmpty ? "none" : inputs.map { "\($0.portType.rawValue) (\($0.portName))" }.joined(separator: ", ")
    }

    /// Mirrors the app's mute (screen taps included) into iOS, so the next stem press goes the right way and the
    /// system mute, which silences the input itself, never outlasts an unmute or the session.
    func setSystemMuted(_ muted: Bool) {
        let was = AVAudioApplication.shared.isInputMuted
        muteLog.info("setInputMuted \(muted, privacy: .public) (was \(was, privacy: .public)) input=\(Self.inputRoute, privacy: .public)")
        guard was != muted else { return }
        echo = muted
        do { try AVAudioApplication.shared.setInputMuted(muted) } catch {
            echo = nil
            muteLog.error("setInputMuted \(muted, privacy: .public): \(error, privacy: .public)")
        }
    }
}
