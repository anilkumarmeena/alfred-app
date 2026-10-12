import AVFoundation
import Foundation
import JarvisAudioCore
import LiveKit
import Network
import UIKit

/// The LiveKit session the page would otherwise join, run natively so it survives the screen lock and background
/// (where the web page is suspended). A singleton so a reloaded page or relaunched bridge finds it via getStatus.
@MainActor
final class VoiceSession: NSObject {
    static let shared = VoiceSession()

    struct Failure: Error {
        let code: String  // as in the plugin's TypeScript definitions
        let message: String
        var retryable = false  // a hiccup, not a refusal
    }

    private struct Wanted: Equatable {
        let server: ServerAddress
        let passcode: String
        let device: String
    }

    private static let transcription = "lk.transcription", chat = "lk.chat"
    private nonisolated static let agentStateKey = "lk.agent.state"  // read in the RoomDelegate callbacks too
    private static let segmentKey = "lk.segment_id"
    private static let speakerKey = "jarvis.speaker"  // "off": the agent makes no speech at all

    /// Event names from definitions.ts.
    var onEvent: ((String, [String: Any]) -> Void)?

    // Set from start() until the session ends. `generation` bumps with it, so async work from an older session
    // (token fetch, retry) drops its result.
    private var wanted: Wanted?
    private var generation = 0

    private var room: Room?
    private var leaving: DisconnectCause?  // set when the agent left, so the disconnect isn't retried
    private var outbox: [String] = []
    private var captions = Captions()
    private let policy = ReconnectPolicy()
    private var attempt = 0
    private var retryTask: Task<Void, Never>?
    private var levelsTask: Task<Void, Never>?
    private var path: NWPathMonitor?
    private var sync = MicSync()
    private var switching = 0  // our own mic track switches in flight; the room's reports of them aren't news
    private let routing = AudioRouting()
    private let airpods = AirPodsMute()
    private let chime = ChimePlayer()
    private let calls = CallWatch()
    private var callQuiet = CallQuiet()
    let micMode = MicMode()

    private(set) var connection = "disconnected"
    private(set) var agentState: String?
    private(set) var muted = false
    /// Transcript-only replies. The agent is told (token, then participant attribute) and its track also plays at
    /// volume 0, so a reply already being spoken stops at once.
    private(set) var speakerOff = false
    private(set) var interrupted = false  // a call, Siri or an alarm holds the audio
    private var engineWaiting = false  // started during a call that held the audio: LiveKit's engine is held back
    private(set) var startedAt: Date?
    var active: Bool { wanted != nil }
    private var agentReady: Bool { agentState != nil && agentState != "initializing" }  // lk.chat would reach it

    override private init() {
        super.init()
        // AudioRouting owns the AVAudioSession; LiveKit only runs the engine.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        // Mute without stopping the engine, so the app stays alive in the background and iOS plays no sound of
        // its own (the chime is ours).
        try? AudioManager.shared.set(microphoneMuteMode: .inputMixer)
        routing.onEvent = { [weak self] in self?.audioEvent($0) }
        airpods.onPress = { [weak self] in self?.airpodsPressed($0) }
        micMode.onChange = { [weak self] in self?.emit("micMode", $0.state) }
        calls.onChange = { [weak self] in self?.callChanged($0) }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    func status() -> [String: Any] {
        var s: [String: Any] = ["connection": connection, "muted": muted, "speakerOff": speakerOff, "interrupted": interrupted]
        if let offer = callQuiet.offer { s["afterCall"] = Self.fields(offer) }
        if let agentState { s["agent"] = agentState }
        if let startedAt { s["startedAt"] = Int(startedAt.timeIntervalSince1970 * 1000) }
        if wanted != nil { s["route"] = routing.route.output }
        s["micMode"] = micMode.state
        return s
    }

    private func emit(_ name: String, _ data: [String: Any]) { onEvent?(name, data) }

    // MARK: - Start and end

    /// Re-reports a running session with the same settings (the page reloaded) instead of rejoining.
    func start(server: ServerAddress, passcode: String, device: String, muted startMuted: Bool, speakerOff startSilent: Bool) async throws -> [String: Any] {
        let w = Wanted(server: server, passcode: passcode, device: device)
        if wanted == w, connection != "disconnected" { return status() }
        if wanted != nil { end(reason: "hangup", message: nil, quiet: true) }

        guard await AVAudioApplication.requestRecordPermission() else {
            throw Failure(code: "NO_MICROPHONE", message: "Microphone access is blocked. Allow it for JARVIS in Settings, then try again.")
        }
        let onCall = calls.onCall
        var audioHeld = false
        do { try routing.activate() } catch {
            // A call holds the audio until it ends; anything else is a real failure.
            guard onCall else {
                routing.deactivate()
                throw Failure(code: "NO_MICROPHONE", message: "The audio session couldn't start: \(error.localizedDescription)")
            }
            audioHeld = true
        }
        wanted = w
        generation += 1
        let gen = generation
        muted = startMuted
        speakerOff = startSilent
        if onCall { startDuringCall(audioHeld: audioHeld) }
        sync = MicSync()
        micMode.sessionStarted()
        // Match iOS's mute to ours before the engine opens the mic.
        airpods.setSystemMuted(muted)
        // Keep the engine running between rooms, so iOS doesn't suspend a background reconnect.
        try? await AudioManager.shared.setRecordingAlwaysPreparedMode(true)
        watchNetwork()
        do {
            try await join(gen, first: true)
        } catch let f as Failure {
            if gen == generation { end(reason: Self.reason(for: f.code), message: f.message) }
            throw f
        }
        // Again now it's connected: the page clears "Mic paused" when the session goes live.
        if gen == generation, interrupted { emit("interruption", ["state": "began"]) }
        return status()
    }

    func stop() {
        guard wanted != nil else { return }
        end(reason: "hangup", message: nil)
    }

    private func end(reason: String, message: String?, quiet: Bool = false) {
        wanted = nil
        generation += 1
        retryTask?.cancel(); retryTask = nil
        if let r = room { drop(r) }  // the levels loop stops itself with no room
        path?.cancel(); path = nil
        connection = "disconnected"; agentState = nil; muted = false; interrupted = false; startedAt = nil
        releaseEngine()
        callQuiet = CallQuiet()
        attempt = 0; outbox.removeAll()
        airpods.setSystemMuted(false)  // iOS keeps it across sessions otherwise
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

    // MARK: - Join

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
        for p in r.remoteParticipants.values where p.kind == .agent { agentChanged(p.attributes[Self.agentStateKey]) }  // joined before us
        if !muted, !interrupted, !(await micOn(r, true)) {
            throw Failure(code: "NO_MICROPHONE", message: "The microphone couldn't start. Allow it for JARVIS in Settings, then try again.")
        }
        if muted || interrupted { airpods.optIn() }  // else micOn does; a muted start must still unmute from the stem
        attempt = 0
        if startedAt == nil { startedAt = Date() }
        setConnection("connected", reason: nil)
        startLevels()
        await applyMic()  // changes made while joining
        await tellSpeaker(r)
    }

    private func fetchToken(_ w: Wanted) async throws -> Grant {
        var req = URLRequest(url: w.server.tokenURL, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = TokenReply.body(passcode: w.passcode, device: w.device, speakerOff: speakerOff)
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
                airpods.optIn()  // the recording session exists only now
                micMode.micLive()
            }
            return true
        } catch {
            NSLog("JarvisAudio: mic \(on): \(error)")
            return false
        }
    }

    // MARK: - Room (RoomDelegate callbacks, hopped onto the main actor)

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
        default: end(reason: "server", message: "The session was closed on the JARVIS computer. Tap the core to reconnect.")
        }
    }

    // MARK: - Reconnect: fresh token and room, until it works or the session is no longer wanted

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

    /// Back online while waiting to retry: go now.
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

    // MARK: - Agent, captions and typed messages

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

    private func requireSession() throws {
        guard wanted != nil else { throw Failure(code: "NOT_CONNECTED", message: "No session is running.") }
    }

    func sendText(_ text: String) throws {
        try requireSession()
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

    // MARK: - Mic

    @discardableResult
    func setMuted(_ m: Bool, source: String) async throws -> Bool {
        try requireSession()
        if source != "call" { callQuiet.settle() }  // the user chose: drop the post-call offer
        muted = m
        sync.changed(at: Self.now)
        // Every change, screen taps included, so the next stem press goes the right way.
        airpods.setSystemMuted(m)
        // Unmuting during an apparent interruption: if iOS hands the audio back, it's over.
        if !m, interrupted, source == "user" { takeAudioBack("unmuted") }
        // With no room (reconnecting), join and roomDidReconnect apply it; an unmute during a call waits for its end.
        let opened = await applyMic()
        if !opened, !m {
            muted = true  // couldn't open the mic: stay muted
            sync.changed(at: Self.now)
            airpods.setSystemMuted(true)
            emit("mute", ["muted": true, "source": "system"])
            summaryChanged()
            throw Failure(code: "NO_MICROPHONE", message: "The microphone couldn't start.")
        }
        emit("mute", ["muted": m, "source": source])
        summaryChanged()
        return m
    }

    /// iOS has already switched the input (and played its tone); the app follows. Our own echoes never get here.
    private func airpodsPressed(_ m: Bool) {
        muteLog.info("stem press muted=\(m, privacy: .public) app muted=\(self.muted, privacy: .public) session=\(self.wanted != nil, privacy: .public)")
        guard wanted != nil, m != muted else { return }  // the observer outlives sessions
        Task { try? await setMuted(m, source: "earphone") }
    }

    /// Live Activity button; the chime is the only feedback off the page. A no-op if already in that state, since
    /// an Apple Watch tap arrives twice.
    func setMutedOffPage(_ m: Bool) async {
        guard wanted != nil, m != muted, (try? await setMuted(m, source: "user")) != nil else { return }
        if !speakerOff { chime.play(muted: m) }
    }

    // MARK: - Speaker

    @discardableResult
    func setSpeaker(off: Bool, source: String) throws -> Bool {
        try requireSession()
        if source != "call" { callQuiet.settle() }
        speakerOff = off
        playAgent()
        if let r = room, connection == "connected" { Task { await tellSpeaker(r) } }  // else join does
        emit("speaker", ["off": off, "source": source])
        return off
    }

    private func tellSpeaker(_ r: Room) async {
        let want = speakerOff ? "off" : "on"
        guard room === r, r.localParticipant.attributes[Self.speakerKey] != want else { return }
        do { try await r.localParticipant.set(attributes: [Self.speakerKey: want]) } catch {
            return NSLog("JarvisAudio: speaker \(want): \(error)")
        }
        if speakerOff != (want == "off") { await tellSpeaker(r) }  // switched again meanwhile
    }

    private func playAgent() {
        guard let r = room else { return }
        for p in r.remoteParticipants.values {
            for t in p.audioTracks { (t.track as? RemoteAudioTrack)?.volume = speakerOff ? 0 : 1 }
        }
    }

    // MARK: - Phone calls

    /// See CallQuiet.
    private func callChanged(_ onCall: Bool) {
        guard wanted != nil else { return }
        if onCall {
            guard callQuiet.began(current) else { return }
            NSLog("JarvisAudio: a call: muting the mic and turning the speaker off")
            emit("call", ["state": "began"])
            if !speakerOff { _ = try? setSpeaker(off: true, source: "call") }
            if !muted { Task { try? await setMuted(true, source: "call") } }
        } else {
            reclaimAudio()
            Task {  // after the mute task above, for a call that ended as soon as it rang
                guard let offer = callQuiet.ended(current) else { return }
                emit("call", ["state": "ended", "restore": Self.fields(offer)])
            }
        }
    }

    /// Started during a call: as a call during a session leaves it, muted with the speaker off, offered back when it
    /// ends. If the call holds the audio, the room is joined without LiveKit's audio engine (typing and captions still
    /// work), which starts once iOS hands the audio over (interruptionOver).
    private func startDuringCall(audioHeld: Bool) {
        NSLog("JarvisAudio: starting during a call: muted, speaker off\(audioHeld ? ", audio engine waiting" : "")")
        _ = callQuiet.began(current)
        muted = true
        speakerOff = true
        emit("mute", ["muted": true, "source": "call"])
        emit("speaker", ["off": true, "source": "call"])
        guard audioHeld else { return }
        interrupted = true
        do {
            try AudioManager.shared.setEngineAvailability(.none)
            engineWaiting = true
        } catch {
            NSLog("JarvisAudio: holding the audio engine: \(error)")
        }
    }

    /// The audio engine may run again, starting whatever playback or recording the room asked for meanwhile.
    private func releaseEngine() {
        guard engineWaiting else { return }
        engineWaiting = false
        do { try AudioManager.shared.setEngineAvailability(.default) } catch {
            NSLog("JarvisAudio: releasing the audio engine: \(error)")
        }
    }

    /// The last call ended: ask for the audio back rather than wait for iOS's interruption end, which never comes for
    /// a session started during the call, or for the app to come on screen. iOS can take a moment to let go of it.
    private func reclaimAudio() {
        let gen = generation
        Task {
            for _ in 0..<10 {
                guard gen == generation, interrupted, !calls.onCall else { return }
                takeAudioBack("call ended")
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func restoreAfterCall(_ restore: Bool) async {
        guard let was = callQuiet.settle(), restore else { return }
        if was.speakerOff != speakerOff { _ = try? setSpeaker(off: was.speakerOff, source: "user") }
        if was.muted != muted { _ = try? await setMuted(was.muted, source: "user") }
    }

    private var current: CallQuiet.State { CallQuiet.State(muted: muted, speakerOff: speakerOff) }

    private static func fields(_ s: CallQuiet.State) -> [String: Any] { ["muted": s.muted, "speakerOff": s.speakerOff] }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Switches the track to MicSync.target after every mute, interruption and (re)connect. `force` ignores
    /// LiveKit's own idea of the track state. False if the switch failed.
    @discardableResult
    private func applyMic(force: Bool = false) async -> Bool {
        guard let r = room, connection == "connected", let on = MicSync.target(muted: muted, interrupted: interrupted) else { return true }
        if !force, r.localParticipant.isMicrophoneEnabled() == on { return true }
        switching += 1
        let ok = await micOn(r, on)
        switching -= 1
        // State changed while switching: catch up.
        if ok, room === r, let next = MicSync.target(muted: muted, interrupted: interrupted), next != on { return await applyMic() }
        return ok
    }

    /// A track mute change we didn't make (server mute, LiveKit stopping a failed mic) is followed, so the page
    /// never says Listening while nothing is sent; a track that comes back on while muted is muted again.
    private func trackMuteChanged(_ isMuted: Bool) {
        guard switching == 0, connection == "connected", sync.settled(at: Self.now) else { return }
        if !isMuted, muted {
            muteLog.info("mic track unmuted while muted: muting it again")
            Task { await applyMic(force: true) }
        } else if isMuted, !muted, !interrupted {
            muteLog.info("mic track muted by the room: showing muted")
            muted = true
            sync.changed(at: Self.now)
            airpods.setSystemMuted(true)
            emit("mute", ["muted": true, "source": "system"])
            summaryChanged()
        }
    }

    private func micHeard() {
        let fix = sync.heard(at: Self.now, muted: muted, interrupted: interrupted)
        if fix.interruptionOver {
            interruptionOver("the mic is heard")  // also re-mutes the track if needed
        } else if fix.muteAgain {
            muteLog.info("mic heard while muted: muting it again")
            Task { await applyMic(force: true) }
        }
    }

    // MARK: - Audio session

    private func audioEvent(_ e: AudioRouting.Event) {
        guard wanted != nil else { return }
        switch e {
        case .interruptionBegan:
            interrupted = true
            sync.changed(at: Self.now)
            micMode.micStopped()
            emit("interruption", ["state": "began"])
            summaryChanged()
        case .interruptionEnded:
            // Even without shouldResume: JARVIS is a call the user left running.
            routing.reactivate()
            interruptionOver("ended")
        case .routeChanged(let output, let input, let reason):
            var d: [String: Any] = ["output": output, "reason": reason]
            if let input { d["input"] = input }
            emit("route", d)
        case .mediaServicesReset:
            // The audio daemon restarted and took everything (interruption included) with it: set up and rejoin.
            if (try? routing.activate()) != nil, interrupted { interruptionOver("media services reset") }
            if let r = room { drop(r) }
            retryLater()
        }
    }

    /// The mic comes back unless muted meanwhile; forced, as the input may need it to restart.
    private func interruptionOver(_ why: String) {
        if interrupted {
            NSLog("JarvisAudio: interruption over (\(why))")
            interrupted = false
            sync.changed(at: Self.now)
            emit("interruption", ["state": "ended"])
            summaryChanged()
        }
        releaseEngine()  // a session started during the call gets its audio now
        Task { await applyMic(force: true) }
    }

    /// iOS doesn't always report an interruption's end, which would leave "Mic paused" up for good. So on foreground
    /// or unmute, ask for the audio again: iOS grants it only if nothing holds it (it refuses during a call). The
    /// other way out is micHeard.
    private func takeAudioBack(_ why: String) {
        guard interrupted, wanted != nil else { return }
        if routing.reactivate() { interruptionOver(why) }
    }

    // MARK: - Voice levels for the reactor, only while in the foreground

    @objc private func appActive() {
        takeAudioBack("app active")
        startLevels()
    }

    private func startLevels() {
        guard levelsTask == nil, room != nil else { return }
        levelsTask = Task { [weak self] in
            var sent: [Double] = []
            while true {
                guard let self, let r = self.room, UIApplication.shared.applicationState == .active else { break }
                let agent = r.remoteParticipants.values.first { $0.kind == .agent }
                let now = [self.muted ? 0 : Double(r.localParticipant.audioLevel), Double(agent?.audioLevel ?? 0)]
                if now != sent {  // skip repeats (mostly silence); the page keeps the last levels
                    self.emit("levels", ["mic": now[0], "agent": now[1]])
                    sent = now
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self?.levelsTask = nil
        }
    }

    // MARK: - Live Activity

    var summary: SessionSummary? {
        SessionSummary(active: wanted != nil, connection: connection, agentState: agentState, muted: muted, interrupted: interrupted)
    }

    /// Call after every change to connection, agent state, mute or interruption.
    private func summaryChanged() {
        SessionControls.changed(summary, startedAt: startedAt)
    }
}

extension VoiceSession: RoomDelegate {
    nonisolated func roomIsReconnecting(_ room: Room) {
        Task { @MainActor in if self.room === room { self.setConnection("reconnecting", reason: "network") } }
    }

    nonisolated func roomDidReconnect(_ room: Room) {
        Task { @MainActor in
            guard self.room === room else { return }
            self.setConnection("connected", reason: nil)
            await self.applyMic()  // changes made while reconnecting
            await self.tellSpeaker(room)
        }
    }

    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        guard participants.contains(where: { $0 is LocalParticipant }) else { return }
        Task { @MainActor in if self.room === room { self.micHeard() } }
    }

    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        guard participant is LocalParticipant, trackPublication.source == .microphone else { return }
        Task { @MainActor in if self.room === room { self.trackMuteChanged(isMuted) } }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in self.roomLost(room, error: error) }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        guard participant.kind == .agent else { return }
        let state = participant.attributes[Self.agentStateKey]
        Task { @MainActor in if self.room === room { self.agentChanged(state) } }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard publication.kind == .audio else { return }
        Task { @MainActor in if self.room === room { self.playAgent() } }  // silent from the first word with the speaker off
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        guard participant.kind == .agent else { return }
        Task { @MainActor in  // as on the page, JARVIS leaving ends the session
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
