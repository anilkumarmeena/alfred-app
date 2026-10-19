import AVFoundation
import Foundation
import LiveKit
import os
import UIKit

let micModeLog = Logger(subsystem: "com.anil.jarvis", category: "micmode")

/// iOS Mic Modes (Standard, Voice Isolation, Wide Spectrum) run inside Apple's voice processing (AUVoiceIO),
/// which LiveKit uses with playAndRecord/voiceChat. Apps can't set the mode (read-only through the iOS 27 SDK),
/// only open the system picker. So the picker opens once per launch when the mic first goes live without Voice
/// Isolation (iOS remembers the choice per app), and the page can open it any time via showMicModes.
@MainActor
final class MicMode: NSObject {
    var onChange: ((MicMode) -> Void)?

    private(set) var active = AVCaptureDevice.activeMicrophoneMode
    private(set) var preferred = AVCaptureDevice.preferredMicrophoneMode  // the user's pick
    private var prompted = false  // auto-opened this launch
    private var due = false  // should open once the app is in the foreground
    private var settle: Task<Void, Never>?
    private var sessionOn = false

    private nonisolated static let keys = ["activeMicrophoneMode", "preferredMicrophoneMode"]

    override init() {
        super.init()
        // Class properties: observe the class object.
        for key in Self.keys { AVCaptureDevice.self.addObserver(self, forKeyPath: key, options: [.new], context: nil) }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath, Self.keys.contains(keyPath) else {
            return super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
        Task { @MainActor [weak self] in self?.refresh() }
    }

    var state: [String: Any] { ["active": Self.name(active), "preferred": Self.name(preferred)] }

    // MARK: - Session

    func sessionStarted() {
        sessionOn = true
        refresh()
    }

    func sessionEnded() {
        sessionOn = false
        micStopped()
    }

    /// Just joined, unmuted, or back after a call.
    func micLive() {
        refresh()
        logProcessing()
        guard !prompted, settle == nil else { return }
        settle = Task { [weak self] in
            // The mode (and Control Center's control) follows the engine's input only once it's running.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.settle = nil
            self.due = true
            self.promptIfDue()
        }
    }

    /// A call took the mic, or the session ended.
    func micStopped() {
        settle?.cancel(); settle = nil
        due = false
    }

    func show() {
        micModeLog.info("showing the picker; active=\(Self.name(self.active), privacy: .public) preferred=\(Self.name(self.preferred), privacy: .public)")
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    private func promptIfDue() {
        guard due, !prompted, sessionOn else { return }
        refresh()
        if preferred == .voiceIsolation || active == .voiceIsolation {  // iOS keeps it per app
            due = false
            return
        }
        guard UIApplication.shared.applicationState == .active else { return }  // retried in appActive
        due = false
        prompted = true
        show()
    }

    @objc private func appActive() {
        refresh()
        promptIfDue()
    }

    private func refresh() {
        let a = AVCaptureDevice.activeMicrophoneMode, p = AVCaptureDevice.preferredMicrophoneMode
        guard a != active || p != preferred else { return }
        active = a; preferred = p
        micModeLog.info("mode active=\(Self.name(a), privacy: .public) preferred=\(Self.name(p), privacy: .public) input=\(AirPodsMute.inputRoute, privacy: .public)")
        onChange?(self)
    }

    /// Mic Modes need Apple's voice processing; logged so an SDK change to WebRTC's software path (no Voice
    /// Isolation) shows up.
    private func logProcessing() {
        Task.detached {
            let vp = AudioManager.shared.platformVoiceProcessingState
            let ap = AudioManager.shared.audioProcessingState
            let category = AVAudioSession.sharedInstance().category.rawValue, mode = AVAudioSession.sharedInstance().mode.rawValue
            micModeLog.info("""
                processing: VPIO enabled=\(vp.voiceProcessingEnabled.isActive, privacy: .public) \
                bypassed=\(vp.voiceProcessingBypassed.isActive, privacy: .public) \
                echo=\(ap.echoCancellation.effective.description, privacy: .public) \
                noise=\(ap.noiseSuppression.effective.description, privacy: .public) \
                session=\(category, privacy: .public)/\(mode, privacy: .public)
                """)
        }
    }

    static func name(_ m: AVCaptureDevice.MicrophoneMode) -> String {
        switch m {
        case .standard: return "standard"
        case .voiceIsolation: return "voiceIsolation"
        case .wideSpectrum: return "wideSpectrum"
        @unknown default: return "other"
        }
    }
}
