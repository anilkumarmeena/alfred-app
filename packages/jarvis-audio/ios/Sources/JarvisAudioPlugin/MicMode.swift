import AVFoundation
import Foundation
import LiveKit
import os
import UIKit

let micModeLog = Logger(subsystem: "com.anil.jarvis", category: "micmode")

/// iOS's Mic Modes: Standard, Voice Isolation and Wide Spectrum. They run inside Apple's voice processing
/// (AUVoiceIO), which LiveKit's engine uses with the playAndRecord / voiceChat session, so Control Center
/// offers them for JARVIS while the mic is on. An app can't choose the mode: up to the iOS 27 SDK,
/// AVCaptureDevice.preferredMicrophoneMode and activeMicrophoneMode are read-only, and the most an app can do
/// is open the system picker. So:
/// - the first time in each launch that the mic goes live in a session and Voice Isolation isn't chosen, the
///   picker opens on its own (when the app is on screen). Once it's chosen, iOS remembers it for the app and
///   the picker stays shut.
/// - the Mic button (top left, during a session) shows the mode in use and opens the picker any time.
/// - both properties are watched with KVO, for the button and the page's micMode events.
@MainActor
final class MicMode: NSObject {
    /// The mode changed: for the page.
    var onChange: ((MicMode) -> Void)?

    private(set) var active = AVCaptureDevice.activeMicrophoneMode  // what's processing the mic now
    private(set) var preferred = AVCaptureDevice.preferredMicrophoneMode  // what the user picked
    private var prompted = false  // the picker opened on its own this launch
    private var due = false  // the mic is live and the picker should open once the app is on screen
    private var settle: Task<Void, Never>?
    private var sessionOn = false
    private weak var button: UIButton?

    private nonisolated static let keys = ["activeMicrophoneMode", "preferredMicrophoneMode"]

    override init() {
        super.init()
        // Class properties, so the class object is what's observed.
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

    // MARK: - The session's side

    func sessionStarted() {
        sessionOn = true
        refresh()
        updateButton()
    }

    func sessionEnded() {
        sessionOn = false
        micStopped()
        updateButton()
    }

    /// The mic is recording in a session: just joined, unmuted, or back after a call.
    func micLive() {
        refresh()
        logProcessing()
        guard !prompted, settle == nil else { return }
        settle = Task { [weak self] in
            // The mode (and Control Center's Mic Mode control) follows the engine's input once it's running.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.settle = nil
            self.due = true
            self.promptIfDue()
        }
    }

    /// A call took the mic, or the session ended: nothing to pick a mode for until the mic is live again.
    func micStopped() {
        settle?.cancel(); settle = nil
        due = false
    }

    /// Apple's Mic Mode picker (Control Center's module for this app).
    func show() {
        micModeLog.info("showing the picker; active=\(Self.name(self.active), privacy: .public) preferred=\(Self.name(self.preferred), privacy: .public)")
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    private func promptIfDue() {
        guard due, !prompted, sessionOn else { return }
        refresh()
        if preferred == .voiceIsolation || active == .voiceIsolation {  // already chosen: iOS keeps it per app
            due = false
            return
        }
        guard UIApplication.shared.applicationState == .active else { return }  // again when the app is on screen
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
        micModeLog.info("mode active=\(Self.name(a), privacy: .public) preferred=\(Self.name(p), privacy: .public) input=\(RemoteControls.inputRoute, privacy: .public)")
        updateButton()
        onChange?(self)
    }

    /// Mic Modes need Apple's voice processing on the input: logged so a later SDK change that moves processing
    /// to WebRTC's software path (which has no Voice Isolation) shows up.
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

    private static func label(_ m: AVCaptureDevice.MicrophoneMode) -> String {
        switch m {
        case .standard: return "Standard"
        case .voiceIsolation: return "Voice Isolation"
        case .wideSpectrum: return "Wide Spectrum"
        @unknown default: return "Other"
        }
    }

    // MARK: - The Mic button

    /// A small pill over the page, under its header on the left, while a session is on. The page is the
    /// live one from the Mac, so this is native rather than part of it.
    func attach(to view: UIView) {
        guard button == nil else { return }
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.accessibilityHint = "Opens iOS's Mic Mode picker"
        b.addAction(UIAction { [weak self] _ in self?.show() }, for: .touchUpInside)
        view.addSubview(b)
        NSLayoutConstraint.activate([
            b.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            b.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 44),
        ])
        button = b
        updateButton()
    }

    private func updateButton() {
        guard let b = button else { return }
        b.isHidden = !sessionOn
        let isolating = active == .voiceIsolation
        var text = "Mic: \(Self.label(active))"
        if preferred != active { text += " (\(Self.label(preferred)) not available here)" }
        let dot = isolating ? UIColor(red: 0.37, green: 0.95, blue: 0.69, alpha: 1) : UIColor(red: 1, green: 0.71, blue: 0.28, alpha: 1)
        let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let title = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: dot, .font: font])
        title.append(NSAttributedString(string: text.uppercased(), attributes: [
            .foregroundColor: UIColor(red: 0.49, green: 0.58, blue: 0.65, alpha: 1), .font: font, .kern: 1.2,
        ]))
        var c = UIButton.Configuration.plain()
        c.attributedTitle = AttributedString(title)
        c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        c.background.backgroundColor = UIColor(red: 0.05, green: 0.10, blue: 0.15, alpha: 0.6)
        c.background.strokeColor = UIColor(red: 0.47, green: 0.78, blue: 0.94, alpha: 0.13)
        c.background.strokeWidth = 1
        c.cornerStyle = .capsule
        b.configuration = c
        b.accessibilityLabel = text
    }
}
