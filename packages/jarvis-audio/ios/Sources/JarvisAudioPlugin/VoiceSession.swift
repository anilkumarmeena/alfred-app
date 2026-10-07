import AVFoundation
import Foundation
import JarvisAudioCore
import LiveKit
import Network
import UIKit

/// JARVIS's voice session, run natively: the same LiveKit room the page would join (a token from jarvis.web's
/// /api/token, then the agent's room), with the mic, JARVIS's voice, captions, agent state and typed messages.
/// With UIBackgroundModes audio and the audio session kept active, it keeps going with the screen locked or
/// the app in the background, where the web page is suspended. It's a singleton so a reloaded page (or a
/// relaunched bridge) finds the running session with getStatus. The plugin forwards what happens to the page.
@MainActor
final class VoiceSession: NSObject {
    static let shared = VoiceSession()

    struct Failure: Error {
        let code: String  // one of the codes in the plugin's TypeScript definitions
        let message: String
        var retryable = false  // a hiccup worth retrying without the user, not a refusal
    }

    private struct Wanted: Equatable {
        let server: ServerAddress
        let passcode: String
        let device: String
    }

    private static let transcription = "lk.transcription", chat = "lk.chat"
    private nonisolated static let agentStateKey = "lk.agent.state"  // read in the RoomDelegate callbacks too
    private static let segmentKey = "lk.segment_id"

    /// Every event for the page: a name from definitions.ts and its data.
    var onEvent: ((String, [String: Any]) -> Void)?

    // What the session should be: set from start() until it ends. `generation` changes whenever it does, so
    // work begun for an older session (a token fetch, a retry) drops its result.
    private var wanted: Wanted?
    private var generation = 0

    private var room: Room?
    private var leaving: DisconnectCause?  // set when the agent left, so the room ending isn't retried
    private var outbox: [String] = []
    private var captions = Captions()
    private let policy = ReconnectPolicy()
    private var attempt = 0
    private var retryTask: Task<Void, Never>?
    private var levelsTask: Task<Void, Never>?
    private var path: NWPathMonitor?
    private let routing = AudioRouting()
    private let airpods = AirPodsMute()
    private let chime = ChimePlayer()
    let micMode = MicMode()

    private(set) var connection = "disconnected"
    private(set) var agentState: String?
    private(set) var muted = false
    private(set) var interrupted = false  // a call, Siri or an alarm has the audio for now
    private(set) var startedAt: Date?
    var active: Bool { wanted != nil }
    private var agentReady: Bool { agentState != nil && agentState != "initializing" }  // lk.chat reaches it

    override private init() {
        super.init()
        // This file owns the AVAudioSession (AudioRouting); LiveKit only runs the engine.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        // Muting silences the input without stopping the engine, so the app stays alive in the background and
        // iOS plays no sound of its own; the chime is ours.
        try? AudioManager.shared.set(microphoneMuteMode: .inputMixer)
        routing.onEvent = { [weak self] in self?.audioEvent($0) }
        airpods.onPress = { [weak self] in self?.airpodsPressed($0) }
        micMode.onChange = { [weak self] in self?.emit("micMode", $0.state) }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    func status() -> [String: Any] {
        var s: [String: Any] = ["connection": connection, "muted": muted, "interrupted": interrupted]
        if let agentState { s["agent"] = agentState }
        if let startedAt { s["startedAt"] = Int(startedAt.timeIntervalSince1970 * 1000) }
        if wanted != nil { s["route"] = routing.route.output }
        s["micMode"] = micMode.state
        return s
    }

    private func emit(_ name: String, _ data: [String: Any]) { onEvent?(name, data) }

    // MARK: - Starting and ending

    /// Joins, or re-reports a session that's already running with the same settings (the page reloaded).
    func start(server: ServerAddress, passcode: String, device: String, muted startMuted: Bool) async throws -> [String: Any] {
        let w = Wanted(server: server, passcode: passcode, device: device)
        if wanted == w, connection != "disconnected" { return status() }
        if wanted != nil { end(reason: "hangup", message: nil, quiet: true) }

        guard await AVAudioApplication.requestRecordPermission() else {
            throw Failure(code: "NO_MICROPHONE", message: "Microphone access is blocked. Allow it for JARVIS in Settings, then try again.")
        }
        do { try routing.activate() } catch {
            throw Failure(code: "NO_MICROPHONE", message: "The audio session couldn't start: \(error.localizedDescription)")
        }
        wanted = w
        generation += 1
        let gen = generation
        muted = startMuted
        micMode.sessionStarted()
        // With iOS's mute matching ours before the engine opens the mic. (micOn opts the recording session in to
        // the AirPods gesture.)
        airpods.setSystemMuted(muted)
        // Keep the audio engine running between rooms too, so a reconnect in the background isn't suspended.
        try? await AudioManager.shared.setRecordingAlwaysPreparedMode(true)
        watchNetwork()
        do {
            try await join(gen, first: true)
        } catch let f as Failure {
            if gen == generation { end(reason: Self.reason(for: f.code), message: f.message) }
            throw f
        }
        return status()
    }

    func stop() {
        guard wanted != nil else { return }
        end(reason: "hangup", message: nil)
    }

    /// Back to no session: leave the room, stop retrying, give the audio session back.
    private func end(reason: String, message: String?, quiet: Bool = false) {
        wanted = nil
        generation += 1
        retryTask?.cancel(); retryTask = nil
        if let r = room { drop(r) }  // the levels loop stops by itself once there's no room
        path?.cancel(); path = nil
        connection = "disconnected"; agentState = nil; muted = false; interrupted = false; startedAt = nil
        attempt = 0; outbox.removeAll()
        airpods.setSystemMuted(false)  // stored across sessions otherwise
        summaryChanged()
        micMode.sessionEnded()
        Task {
            guard self.wanted == nil else { return }  // a new session started meanwhile
            try? await AudioManager.shared.setRecordingAlwaysPreparedMode(false)
            if self.wanted == nil { self.routing.deactivate() }
        }
        if !quiet {
            var e: [String: Any] = ["state": "disconnected", "reason": reason]
            if let message { e["message"] = message }
            emit("connection", e)
        }
    }

    private func drop(_ r: Room) {
        if room === r { room = nil }
        r.remove(delegate: self)
        Task { await r.disconnect() }
    }

    private static func reason(for code: String) -> String {
        switch code {
        case "UNAUTHORIZED": return "unauthorized"
        case "RATE_LIMITED": return "rateLimited"
        case "NO_MICROPHONE": return "microphone"
        default: return "server"
        }
    }

    // MARK: - Joining

    private func join(_ gen: Int, first: Bool) async throws {
        guard let w = wanted else { return }
        setConnection(first ? "connecting" : "reconnecting", reason: first ? nil : "network")
        let grant = try await fetchToken(w)
        guard gen == generation else { return }

        let r = Room(delegate: self)
        room = r; leaving = nil; agentState = nil; captions = Captions()
        try? await r.registerTextStreamHandler(for: Self.transcription) { [weak self] reader, from in
            await self?.caption(r, reader, from: from.stringValue)
        }
        do {
            try await r.connect(url: grant.url, token: grant.token)
        } catch {
            if room === r { drop(r) }
            throw Failure(code: "SERVER", message: "Couldn't join the session: \(error.localizedDescription)", retryable: true)
        }
        guard gen == generation, room === r else { return }
        for p in r.remoteParticipants.values where p.kind == .agent { agentChanged(p.attributes[Self.agentStateKey]) }  // there before us
        if !muted, !interrupted, !(await micOn(r, true)) {
            throw Failure(code: "NO_MICROPHONE", message: "The microphone couldn't start. Allow it for JARVIS in Settings, then try again.")
        }
        if muted || interrupted { airpods.optIn() }  // micOn does it otherwise; a muted start can still unmute from the stem
        attempt = 0
        if startedAt == nil { startedAt = Date() }
        setConnection("connected", reason: nil)
        startLevels()
    }

    private func fetchToken(_ w: Wanted) async throws -> Grant {
        var req = URLRequest(url: w.server.tokenURL, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = TokenReply.body(passcode: w.passcode, device: w.device)
        let data: Data, status: Int
        do {
            let (d, response) = try await URLSession.shared.data(for: req)
            data = d
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw Failure(code: "SERVER", message: "Couldn't reach JARVIS at \(w.server.host).", retryable: true)
        }
        switch TokenReply.parse(status: status, body: data) {
        case .success(let grant): return grant
        case .failure(let e): throw Failure(code: e.code, message: e.message, retryable: e.isRetryable)
        }
    }

    private func micOn(_ r: Room, _ on: Bool) async -> Bool {
        do {
            try await r.localParticipant.setMicrophone(enabled: on)
            if on {
                airpods.optIn()  // now that it's recording, so the AirPods stem can mute this session
                micMode.micLive()  // and Control Center offers Mic Mode: open it if Voice Isolation isn't chosen
            }
            return true
        } catch {
            NSLog("JarvisAudio: mic \(on): \(error)")
            return false
        }
    }

    // MARK: - The room (RoomDelegate callbacks, hopped onto the main actor)

    private func roomLost(_ r: Room, error: LiveKitError?) {
        guard room === r else { return }
        let cause: DisconnectCause = leaving ?? {
            switch error?.type {
            case nil, .cancelled: return .clientInitiated
            case .duplicateIdentity: return .duplicateIdentity
            case .participantRemoved, .roomDeleted, .serverShutdown: return .removed
            case .network, .timedOut, .serverPingTimedOut, .webRTC: return .network
            default: return .unknown
            }
        }()
        NSLog("JarvisAudio: room ended: \(String(describing: error)) → \(cause)")
        drop(r)
        if wanted != nil, cause.shouldReconnect { return retryLater() }
        switch cause {
        case .agentLeft: end(reason: "agentLeft", message: "JARVIS ended the session. Tap the core to reconnect.")
        case .clientInitiated: end(reason: "hangup", message: nil)
        default: end(reason: "server", message: "The session was closed on the Mac. Tap the core to reconnect.")
        }
    }

    // MARK: - Reconnecting: a fresh token and a fresh room, until it works or the session is no longer wanted

    private func retryLater() {
        attempt += 1
        let wait = policy.delay(attempt: attempt)
        setConnection("reconnecting", reason: "network", retryIn: wait)
        let gen = generation
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.retryNow(gen)
        }
    }

    private func retryNow(_ gen: Int) async {
        guard gen == generation, wanted != nil, room == nil else { return }
        do {
            try await join(gen, first: false)
        } catch let f as Failure {
            guard gen == generation else { return }
            if f.retryable { retryLater() } else { end(reason: Self.reason(for: f.code), message: f.message) }
        } catch {
            if gen == generation { retryLater() }
        }
    }

    /// Back online while waiting to retry: go now rather than at the end of the wait.
    private func watchNetwork() {
        guard path == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] p in
            guard p.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, let task = self.retryTask, !task.isCancelled, self.room == nil else { return }
                task.cancel()
                let gen = self.generation
                self.retryTask = Task { await self.retryNow(gen) }
            }
        }
        monitor.start(queue: .main)
        path = monitor
    }

    private func setConnection(_ state: String, reason: String?, retryIn: TimeInterval? = nil) {
        connection = state
        var e: [String: Any] = ["state": state]
        if let reason { e["reason"] = reason }
        if state == "reconnecting", attempt > 0 { e["attempt"] = attempt }
        if let retryIn { e["retryIn"] = Int(retryIn * 1000) }
        emit("connection", e)
        if state == "connected" { flush() }
        summaryChanged()
    }

    // MARK: - The agent, captions and typed messages

    private func agentChanged(_ value: String?) {
        guard let state = AgentStates.parse(value) else { return }
        agentState = state
        emit("agentState", ["state": state])
        flush()
        summaryChanged()
    }

    private func caption(_ r: Room, _ reader: TextStreamReader, from: String) async {
        let id = reader.info.attributes[Self.segmentKey] ?? reader.info.id
        let speaker = Captions.speaker(sender: from, local: r.localParticipant.identity?.stringValue)
        captions.begin(id: id)
        do {
            for try await chunk in reader where room === r {
                send(captions.append(id: id, chunk: chunk, speaker: speaker))
            }
        } catch {
            NSLog("JarvisAudio: caption \(id): \(error)")
        }
        if room === r { send(captions.append(id: id, chunk: "", speaker: speaker, final: true)) }
    }

    private func send(_ l: Captions.Line) {
        emit("transcript", ["id": l.id, "speaker": l.speaker, "text": l.text, "final": l.final])
    }

    func sendText(_ text: String) throws {
        guard wanted != nil else { throw Failure(code: "NOT_CONNECTED", message: "No session is running.") }
        outbox.append(text)
        flush()
    }

    private func flush() {
        guard let r = room else { return }
        while agentReady, connection == "connected", !outbox.isEmpty {
            let text = outbox.removeFirst()
            Task {
                do { _ = try await r.localParticipant.sendText(text, for: Self.chat) } catch { NSLog("JarvisAudio: lk.chat: \(error)") }
            }
        }
    }

    // MARK: - The mic

    @discardableResult
    func setMuted(_ m: Bool, source: String) async throws -> Bool {
        guard wanted != nil else { throw Failure(code: "NOT_CONNECTED", message: "No session is running.") }
        muted = m
        // iOS is told about every change, taps on the screen included, so it agrees with the app and the next stem
        // press goes the right way. The notification it sends back is dropped as an echo (AirPodsMute).
        airpods.setSystemMuted(m)
        // With no room yet (reconnecting) or a call holding the audio, the choice is kept and applied later.
        var opened = true
        if let r = room, connection == "connected", !interrupted { opened = await micOn(r, !m) }
        if !opened, !m {
            muted = true  // couldn't open the mic: stay muted and say so
            airpods.setSystemMuted(true)
            emit("mute", ["muted": true, "source": "system"])
            summaryChanged()
            throw Failure(code: "NO_MICROPHONE", message: "The microphone couldn't start.")
        }
        emit("mute", ["muted": m, "source": source])
        summaryChanged()
        return m
    }

    /// The AirPods gesture: iOS has muted or unmuted the input already (and played its own tone), so the app
    /// follows iOS's state. Echoes of our own setSystemMuted never get here.
    private func airpodsPressed(_ m: Bool) {
        muteLog.info("stem press muted=\(m, privacy: .public) app muted=\(self.muted, privacy: .public) session=\(self.wanted != nil, privacy: .public)")
        guard wanted != nil, m != muted else { return }  // the mute-state observer runs for the app's lifetime
        Task { try? await setMuted(m, source: "earphone") }
    }

    /// A tap on the Live Activity's button, with the chime as the only sign of it off the page. Ignored when
    /// it's that way already: a tap on Apple Watch arrives twice.
    func setMutedOffPage(_ m: Bool) async {
        guard wanted != nil, m != muted, (try? await setMuted(m, source: "user")) != nil else { return }
        chime.play(muted: m)
    }

    // MARK: - The audio session

    private func audioEvent(_ e: AudioRouting.Event) {
        guard wanted != nil else { return }
        switch e {
        case .interruptionBegan:
            interrupted = true
            micMode.micStopped()
            emit("interruption", ["state": "began"])
            summaryChanged()
        case .interruptionEnded:
            // Take the audio back even without shouldResume: JARVIS is a call the user left running.
            routing.reactivate()
            interrupted = false
            emit("interruption", ["state": "ended"])
            if let r = room, connection == "connected", !muted { Task { _ = await micOn(r, true) } }
            summaryChanged()
        case .routeChanged(let output, let input, let reason):
            var d: [String: Any] = ["output": output, "reason": reason]
            if let input { d["input"] = input }
            emit("route", d)
        case .mediaServicesReset:
            // The audio daemon restarted: everything audio is gone. Set the session up again and rejoin.
            try? routing.activate()
            if let r = room { drop(r) }
            retryLater()
        }
    }

    // MARK: - Voice levels for the reactor, only while on screen

    @objc private func appActive() { startLevels() }

    private func startLevels() {
        guard levelsTask == nil, room != nil else { return }
        levelsTask = Task { [weak self] in
            var sent: [Double] = []
            while true {
                guard let self, let r = self.room, UIApplication.shared.applicationState == .active else { break }
                let agent = r.remoteParticipants.values.first { $0.kind == .agent }
                let now = [self.muted ? 0 : Double(r.localParticipant.audioLevel), Double(agent?.audioLevel ?? 0)]
                if now != sent {  // the page keeps the last levels, so repeats (mostly silence) needn't cross the bridge
                    self.emit("levels", ["mic": now[0], "agent": now[1]])
                    sent = now
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self?.levelsTask = nil
        }
    }

    // MARK: - Outside the page: the lock screen

    /// What the session is doing, for the user, or nil with no session.
    var summary: SessionSummary? {
        SessionSummary(active: wanted != nil, connection: connection, agentState: agentState, muted: muted, interrupted: interrupted)
    }

    /// Called after every change to the connection, the agent's state, the mute or an interruption: the one
    /// place that keeps the app's Live Activity, the one surface outside the page, up to date.
    private func summaryChanged() {
        SessionControls.changed(summary, startedAt: startedAt)
    }
}

extension VoiceSession: RoomDelegate {
    nonisolated func roomIsReconnecting(_ room: Room) {
        Task { @MainActor in if self.room === room { self.setConnection("reconnecting", reason: "network") } }
    }

    nonisolated func roomDidReconnect(_ room: Room) {
        Task { @MainActor in if self.room === room { self.setConnection("connected", reason: nil) } }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in self.roomLost(room, error: error) }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        guard participant.kind == .agent else { return }
        let state = participant.attributes[Self.agentStateKey]
        Task { @MainActor in if self.room === room { self.agentChanged(state) } }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        guard participant.kind == .agent else { return }
        Task { @MainActor in  // as the page does: JARVIS leaving ends the session
            guard self.room === room else { return }
            self.leaving = .agentLeft
            await room.disconnect()
        }
    }

    nonisolated func room(_ room: Room, participant: Participant, didUpdateAttributes attributes: [String: String]) {
        guard let state = attributes[Self.agentStateKey] else { return }
        Task { @MainActor in if self.room === room { self.agentChanged(state) } }
    }

    nonisolated func room(_ room: Room, participant: Participant, didUpdateConnectionQuality quality: ConnectionQuality) {
        guard participant is LocalParticipant else { return }
        let q: String
        switch quality {
        case .excellent: q = "excellent"
        case .good: q = "good"
        case .poor: q = "poor"
        case .lost: q = "lost"
        default: q = "unknown"
        }
        Task { @MainActor in if self.room === room { self.emit("quality", ["quality": q]) } }
    }
}
