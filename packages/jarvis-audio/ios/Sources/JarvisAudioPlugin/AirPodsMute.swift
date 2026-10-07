import AVFoundation
import Foundation
import os

let muteLog = Logger(subsystem: "com.anil.jarvis", category: "mute")

/// The AirPods stem press (and some Beats) on iOS 17+: the system's mute gesture (Press to Mute). During a
/// playAndRecord session iOS mutes or unmutes the app's input itself on a stem press, and says so with
/// AVAudioApplication.inputMuteStateChangeNotification. Adding an observer for that notification is what opts the
/// app in: iOS hooks it and marks each of the app's audio sessions that exists at that moment as wanting the
/// gesture (PrefersBluetoothAccessoryMuting). A session created later starts unmarked, and a stem press on it
/// gets "Cannot control mic with AirPods". So the observer is added when this is created and again, by optIn(),
/// once the mic is recording and every session the engine uses exists. VoiceSession ignores it with no session.
@MainActor
final class AirPodsMute {
    /// iOS has already muted or unmuted the input.
    var onPress: ((_ muted: Bool) -> Void)?
    private var observer: NSObjectProtocol?
    private var echo: Bool?  // what setSystemMuted just gave iOS: its notification comes back and is dropped

    init() { optIn() }

    /// (Re)adds the mute-state observer, which (re)opts every audio session the app has now into the AirPods gesture.
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

    /// The input route, for the log: BluetoothHFP is AirPods (or another headset's mic), MicrophoneBuiltIn the phone.
    static var inputRoute: String {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        return inputs.isEmpty ? "none" : inputs.map { "\($0.portType.rawValue) (\($0.portName))" }.joined(separator: ", ")
    }

    /// Keeps the system's input mute in step with the app's, taps on the screen included, so the next stem press
    /// goes the right way and iOS's mute (which silences the input itself) never outlasts an unmute or the
    /// session. The notification iOS sends back for it is dropped as an echo.
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
