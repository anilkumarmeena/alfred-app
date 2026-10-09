import AVFoundation
import Foundation

/// The app's AVAudioSession: playAndRecord for a voice chat, kept active for the whole session so iOS keeps
/// the app running in the background (UIBackgroundModes audio), with Bluetooth headsets and AirPods allowed
/// for both directions and the speaker, not the earpiece, when nothing is plugged in. LiveKit's own session
/// handling is switched off (see VoiceSession), so this is the one place it's set up.
///
/// It also reports what happens to the session: interruptions (a phone call, Siri, an alarm), route changes
/// (AirPods in or out) and media services resets.
@MainActor
final class AudioRouting {
    enum Event {
        case interruptionBegan
        case interruptionEnded
        case routeChanged(output: String, input: String?, reason: String)
        case mediaServicesReset
    }

    var onEvent: ((Event) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private let session = AVAudioSession.sharedInstance()

    #if swift(>=6.2)
    private static let bluetooth: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP]
    #else
    private static let bluetooth: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
    #endif

    func activate() throws {
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: Self.bluetooth.union([.defaultToSpeaker, .allowAirPlay]))
        try session.setActive(true)
        observe()
    }

    func deactivate() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// After an interruption, iOS leaves the session inactive until the app asks again. False while something with
    /// a higher priority (a phone call, Siri) still holds the audio.
    @discardableResult
    func reactivate() -> Bool {
        do { try session.setActive(true); return true } catch {
            NSLog("JarvisAudio: reactivate failed: \(error)")
            return false
        }
    }

    /// What's in use now, e.g. ("AirPods Pro", "AirPods Pro") or ("Speaker", "iPhone Microphone").
    var route: (output: String, input: String?) {
        let r = session.currentRoute
        return (r.outputs.first?.portName ?? "Speaker", r.inputs.first?.portName)
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] n in
            let info = n.userInfo ?? [:]
            guard let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            MainActor.assumeIsolated {
                switch type {
                case .began: self?.onEvent?(.interruptionBegan)
                case .ended: self?.onEvent?(.interruptionEnded)
                @unknown default: break
                }
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
            MainActor.assumeIsolated {
                guard let self else { return }
                let r = self.route
                self.onEvent?(.routeChanged(output: r.output, input: r.input, reason: Self.name(reason)))
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.mediaServicesReset) }
        })
    }

    private static func name(_ r: AVAudioSession.RouteChangeReason) -> String {
        switch r {
        case .newDeviceAvailable: return "newDevice"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRoute"
        case .routeConfigurationChange: return "configurationChange"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
}
